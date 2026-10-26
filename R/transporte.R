# ============================================================
# transporte.R
# Planificación de viajes en transporte público (colectivo, subte,
# tren y tramos a pie) con OpenTripPlanner (OTP), y consulta de
# frecuencias en data/transporte.sqlite.
#
# Requisitos: servidor OTP local en OTP_URL (ver GUIA_BETA.md).
# Todos los horarios son PROGRAMADOS (GTFS), no en tiempo real.
# ============================================================

suppressPackageStartupMessages(library(data.table))

OTP_BASE <- "http://localhost:8080/otp/routers/default"
TZ_CABA <- "America/Argentina/Buenos_Aires"
RUTA_DB_TRANSPORTE <- file.path(RUTA_DATOS, "transporte.sqlite")

#' Indica si el servidor OTP local responde.
servidor_otp_disponible <- function() {
  tryCatch({
    r <- httr::GET(OTP_BASE, httr::timeout(3))
    httr::status_code(r) < 500
  }, error = function(e) FALSE)
}

#' Decodifica una polilínea codificada (formato Google, precisión 1e-5).
#' OTP devuelve la geometría de cada tramo con este formato.
decodificar_polilinea <- function(s) {
  if (is.null(s) || is.na(s) || s == "") return(matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat"))))
  b <- utf8ToInt(s) - 63L
  i <- 1L; lat <- 0; lng <- 0
  out_lat <- numeric(0); out_lng <- numeric(0)
  while (i <= length(b)) {
    for (k in 1:2) {
      shift <- 0; resultado <- 0
      repeat {
        byte <- b[i]; i <- i + 1L
        resultado <- resultado + bitwAnd(byte, 31L) * 2^shift
        shift <- shift + 5
        if (byte < 32L) break
      }
      delta <- if (resultado %% 2 == 1) -(resultado + 1) / 2 else resultado / 2
      if (k == 1) lat <- lat + delta else lng <- lng + delta
    }
    out_lat <- c(out_lat, lat / 1e5)
    out_lng <- c(out_lng, lng / 1e5)
  }
  cbind(lon = out_lng, lat = out_lat)
}

#' Quita el prefijo "feed:" de los ids de OTP (ej. "colectivos-gtfs-2019-10-01:1234" -> "1234").
id_gtfs <- function(id) {
  if (is.null(id) || is.na(id)) return(NA_character_)
  sub("^[^:]*:", "", id)
}

#' Pasa un milisegundo epoch de OTP a hora local de CABA.
desde_epoch_ms <- function(ms) {
  as.POSIXct(ms / 1000, origin = "1970-01-01", tz = TZ_CABA)
}

#' Nombre legible de un modo de OTP.
nombre_modo <- function(modo) {
  c(WALK = "Caminar", BUS = "Colectivo", SUBWAY = "Subte", RAIL = "Tren",
    TRAM = "Tranvía", FERRY = "Ferry")[modo] %||% modo
}

#' Espera media programada (min) de una línea en una parada, para una franja horaria.
#' Lee la tabla `conectividad` de data/transporte.sqlite.
#' @return numeric (NA si la línea no pasa por esa parada en esa franja)
consultar_espera <- function(ruta, parada, franja = "Manana") {
  topo <- cargar_topologia()
  col <- paste0("espera_", tolower(franja), "_min")
  fila <- topo$conectividad[id_ruta == ruta & id_parada_origen == parada][1]
  if (nrow(fila) == 0) return(NA_real_)
  fila[[col]]
}

# ============================================================
# Topología de colectivos con sesgo de riesgo
# ============================================================
# Modelo: grafo de estados (línea, parada). Un viaje en colectivo es:
#   parada --subida--> (línea, parada) --viaje--> (línea, parada siguiente) ... --bajada--> parada
# La espera y la penalización por transbordo se cargan SOLO al subir, así que cada
# subida (y cada transbordo) se cuenta una vez.
#
# Costo de cada arista (Dijkstra):
#   w = (tiempo_base + espera_franja / 2 [solo subida]) * (1 + factor_sesgo * score)
# score = promedio de score_riesgo de las paradas que une la arista (0 si no hay dato).
# factor_sesgo = 0 da la ruta más rápida; valores altos la desvían de zonas de riesgo.

# Supuestos (ver README, sección "Supuestos del ruteo")
VELOCIDAD_CAMINATA_M_MIN <- 80        # ~4,8 km/h
PENALIZACION_SUBIDA_MIN <- 3          # costo fijo por cada subida (transbordo incluido)
DISTANCIA_TRANSBORDO_M <- 150         # caminata máxima entre dos paradas para transbordar
RADIO_ACCESO_M <- 500                 # caminata preferida hasta la primera/última parada
RADIOS_ACCESO_M <- c(500, 800, 1200)  # radios sucesivos si no hay paradas dentro del primero
VALOR_SIN_SERVICIO_MIN <- 1e6         # tramo sin servicio en la franja: peso enorme

# Caché en memoria: la base se lee y el grafo se arma una sola vez por sesión.
.cache_transporte <- new.env(parent = emptyenv())

#' Lee las tres tablas de la base de topología (con caché).
cargar_topologia <- function(ruta_db = RUTA_DB_TRANSPORTE) {
  if (!is.null(.cache_transporte$topo)) return(.cache_transporte$topo)
  if (!requireNamespace("RSQLite", quietly = TRUE)) stop("Falta el paquete RSQLite.")
  if (!file.exists(ruta_db)) stop("No existe ", ruta_db, ". Correr R/03_base_transporte.R.")
  con <- DBI::dbConnect(RSQLite::SQLite(), ruta_db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  topo <- list(
    paradas = as.data.table(DBI::dbReadTable(con, "paradas_riesgo")),
    lineas = as.data.table(DBI::dbReadTable(con, "lineas_recorridos")),
    conectividad = as.data.table(DBI::dbReadTable(con, "conectividad"))
  )
  .cache_transporte$topo <- topo
  topo
}

#' Distancia en metros entre un punto y muchos (Haversine, vectorizada).
distancias_m <- function(lat, lon, lats, lons) {
  r <- 6371000
  p1 <- lat * pi / 180; p2 <- lats * pi / 180
  dp <- (lats - lat) * pi / 180; dl <- (lons - lon) * pi / 180
  a <- sin(dp / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  2 * r * asin(pmin(1, sqrt(a)))
}

#' Franja horaria según la hora (por defecto, la actual).
franja_actual <- function(hora = format(Sys.time(), "%H")) {
  h <- as.integer(hora)
  if (h >= 6 && h < 12) "Manana" else if (h >= 12 && h < 20) "Tarde" else "Noche"
}

#' Construye el grafo de estados (igraph). Vértices "P:<parada>" y "L:<línea>|<parada>".
#' Se arma una sola vez por sesión (ver `obtener_grafo_colectivos()`).
construir_grafo_colectivos <- function(topo = cargar_topologia(),
                                       distancia_transbordo = DISTANCIA_TRANSBORDO_M) {
  if (!requireNamespace("igraph", quietly = TRUE)) stop("Falta el paquete igraph.")
  paradas <- topo$paradas
  con <- topo$conectividad
  score_p <- setNames(ifelse(is.na(paradas$score_riesgo), 0, paradas$score_riesgo), paradas$id_parada)

  # Estados (línea, parada): origen y destino de cada tramo
  est_origen <- con[, .(id_ruta, id_parada = id_parada_origen,
                        espera_manana_min, espera_tarde_min, espera_noche_min)]
  est_origen <- est_origen[!duplicated(est_origen[, .(id_ruta, id_parada)])]
  est_destino <- con[, .(id_ruta, id_parada = id_parada_destino)]
  est_destino <- est_destino[!duplicated(est_destino)]
  est <- merge(est_destino, est_origen, by = c("id_ruta", "id_parada"), all.x = TRUE)
  est[, nodo := paste0("L:", id_ruta, "|", id_parada)]
  est[, p_nodo := paste0("P:", id_parada)]

  # Subida: parada -> estado. Solo en paradas donde la línea tiene servicio (con espera conocida)
  subida <- est[!is.na(espera_manana_min), .(
    from = p_nodo, to = nodo, tipo = "subida", id_ruta, id_parada,
    tiempo = PENALIZACION_SUBIDA_MIN, espera_manana = espera_manana_min,
    espera_tarde = espera_tarde_min, espera_noche = espera_noche_min
  )]
  # Bajada: estado -> parada (sin costo)
  bajada <- est[, .(from = nodo, to = p_nodo, tipo = "bajada", id_ruta, id_parada,
                    tiempo = 0, espera_manana = NA_real_, espera_tarde = NA_real_, espera_noche = NA_real_)]
  # Viaje: estado (línea, origen) -> estado (línea, destino)
  viaje <- con[, .(from = paste0("L:", id_ruta, "|", id_parada_origen),
                   to = paste0("L:", id_ruta, "|", id_parada_destino),
                   tipo = "viaje", id_ruta, id_parada = id_parada_origen,
                   tiempo = tiempo_estimado_entre_paradas,
                   espera_manana = NA_real_, espera_tarde = NA_real_, espera_noche = NA_real_)]
  # Transbordo a pie entre paradas cercanas (sin penalización extra: la subida ya la tiene)
  pts <- sf::st_as_sf(paradas, coords = c("lng", "lat"), crs = CRS_GEOGRAFICO, remove = FALSE)
  pts <- sf::st_transform(pts, CRS_PROYECTADO)
  xy <- sf::st_coordinates(pts)
  vecinos <- sf::st_is_within_distance(pts, pts, dist = distancia_transbordo)
  pares <- data.table(i = rep(seq_along(vecinos), lengths(vecinos)), j = unlist(vecinos))
  pares <- pares[i != j]
  pares[, dist := sqrt((xy[i, 1] - xy[j, 1])^2 + (xy[i, 2] - xy[j, 2])^2)]
  caminata <- pares[, .(from = paste0("P:", paradas$id_parada[i]), to = paste0("P:", paradas$id_parada[j]),
                        tipo = "caminata", id_ruta = NA_character_, id_parada = paradas$id_parada[i],
                        tiempo = dist / VELOCIDAD_CAMINATA_M_MIN,
                        espera_manana = NA_real_, espera_tarde = NA_real_, espera_noche = NA_real_)]

  aristas <- rbindlist(list(subida, viaje, bajada, caminata), use.names = TRUE)
  # Score de la arista: promedio de las paradas que une (en el nodo "P:" o en la parada del estado)
  parada_de <- function(nodo) sub("^(P:|L:[^|]*\\|)", "", nodo)
  aristas[, score := (score_p[parada_de(from)] + score_p[parada_de(to)]) / 2]
  aristas[is.na(score), score := 0]

  vertices <- unique(c(aristas$from, aristas$to))
  g <- igraph::graph_from_data_frame(
    d = aristas[, .(from, to, tipo, id_ruta, id_parada, tiempo, espera_manana, espera_tarde, espera_noche, score)],
    directed = TRUE,
    vertices = data.frame(name = vertices, stringsAsFactors = FALSE)
  )
  g
}

#' Grafo cacheado (se construye la primera vez).
obtener_grafo_colectivos <- function() {
  if (is.null(.cache_transporte$grafo)) .cache_transporte$grafo <- construir_grafo_colectivos()
  .cache_transporte$grafo
}

#' Pesos de cada arista para una franja y un factor de sesgo.
#' Las aristas sin servicio en la franja (espera NA en subida) reciben VALOR_SIN_SERVICIO_MIN.
pesos_aristas <- function(g, franja, factor_sesgo) {
  tipo <- igraph::edge_attr(g, "tipo")
  tiempo <- igraph::edge_attr(g, "tiempo")
  esp <- igraph::edge_attr(g, paste0("espera_", tolower(franja)))
  sc <- igraph::edge_attr(g, "score")
  base <- tiempo + ifelse(tipo == "subida", esp / 2, 0)
  base[is.na(base)] <- VALOR_SIN_SERVICIO_MIN
  base * (1 + factor_sesgo * sc)
}

#' Ruta de colectivo con sesgo de riesgo entre dos puntos.
#'
#' Busca paradas a pie (<= RADIO_ACCESO_M) cerca de origen y destino, y calcula hasta
#' `k_alternativas` caminos mínimos (Dijkstra) con costo ponderado por riesgo. Las alternativas
#' se obtienen penalizando los tramos del camino anterior, para que sean distintas.
#'
#' @param origen_coords,destino_coords list(lat, lon)
#' @param franja "Manana", "Tarde" o "Noche" (NULL = franja de la hora actual)
#' @param factor_sesgo 0 = ruta más rápida; > 0 penaliza paradas y tramos de mayor riesgo
#' @param k_alternativas máximo de rutas distintas a devolver
#' @return lista de rutas; cada una con costo, duracion_min, espera_min, caminata_min,
#'   transbordos, riesgo_medio, exposicion, tramos (data.frame) y paradas (vector)
calcular_colectivo_seguro <- function(origen_coords, destino_coords, franja = NULL,
                                      factor_sesgo = 1, k_alternativas = 3) {
  if (is.null(franja)) franja <- franja_actual()
  g <- obtener_grafo_colectivos()
  paradas <- cargar_topologia()$paradas

  # Acceso escalonado: si no hay paradas dentro de RADIO_ACCESO_M, se amplía el radio.
  # La caminata extra queda cargada en el tiempo, así que la ruta lo penaliza.
  acceso <- function(pt) {
    d <- distancias_m(pt$lat, pt$lon, paradas$lat, paradas$lng)
    for (radio in RADIOS_ACCESO_M) {
      cerca <- which(d <= radio)
      if (length(cerca) > 0) {
        return(data.table(id_parada = paradas$id_parada[cerca], caminata = d[cerca] / VELOCIDAD_CAMINATA_M_MIN,
                          score = ifelse(is.na(paradas$score_riesgo[cerca]), 0, paradas$score_riesgo[cerca])))
      }
    }
    stop("No hay paradas de colectivo a menos de ", max(RADIOS_ACCESO_M), " m del punto.")
  }
  ac_o <- acceso(origen_coords)
  ac_d <- acceso(destino_coords)

  # Vértices virtuales ORIG y DEST, unidos a las paradas de acceso y de egreso a pie
  g <- igraph::add_vertices(g, 2, name = c("ORIG", "DEST"))
  nuevos <- rbind(
    data.table(from = "ORIG", to = paste0("P:", ac_o$id_parada), caminata = ac_o$caminata, score = ac_o$score),
    data.table(from = paste0("P:", ac_d$id_parada), to = "DEST", caminata = ac_d$caminata, score = ac_d$score)
  )
  g <- igraph::add_edges(g, as.vector(t(as.matrix(nuevos[, .(from, to)]))),
                         attr = list(tipo = "acceso", id_ruta = NA_character_, id_parada = NA_character_,
                                     tiempo = nuevos$caminata, espera_manana = NA_real_,
                                     espera_tarde = NA_real_, espera_noche = NA_real_,
                                     score = nuevos$score))

  w_iter <- pesos_aristas(g, franja, factor_sesgo)
  rutas <- list()
  usados <- character(0)
  for (k in seq_len(k_alternativas)) {
    sp <- igraph::shortest_paths(g, from = "ORIG", to = "DEST", weights = w_iter,
                                 output = "epath", algorithm = "dijkstra")
    ep <- as.integer(sp$epath[[1]])
    if (length(ep) == 0) break
    firma <- paste(sort(ep), collapse = "-")
    if (!(firma %in% usados)) {
      usados <- c(usados, firma)
      rutas <- c(rutas, list(resumir_ruta(g, ep, franja, factor_sesgo,
                                          coords_od = list(origen = origen_coords, destino = destino_coords))))
    }
    w_iter[ep] <- w_iter[ep] * 2   # penaliza el camino hallado para buscar otro distinto
  }
  if (length(rutas) == 0) stop("No se encontró un recorrido en colectivo entre los puntos.")
  rutas
}

#' Frontera de Pareto entre tiempo y exposición al riesgo para un par de puntos.
#'
#' Corre `calcular_colectivo_seguro()` con varios factores de sesgo y junta todas las rutas
#' obtenidas. Devuelve solo las no dominadas: una ruta se descarta si otra es igual o mejor
#' en tiempo y en exposición, y estrictamente mejor en una de las dos.
#'
#' @param factores valores de factor_sesgo a barrer (0 = ruta más rápida)
#' @return lista con `opciones` (data.frame ordenado por tiempo: id, duracion_min,
#'   exposicion, transbordos, caminata_min, factor) y `rutas` (las rutas completas, mismo orden)
frontera_pareto_transporte <- function(origen_coords, destino_coords, franja = NULL,
                                       factores = c(0, 1, 2, 3, 5, 7, 10), k_alternativas = 2) {
  if (is.null(franja)) franja <- franja_actual()
  candidatas <- list(); meta <- list()
  for (f in factores) {
    rs <- calcular_colectivo_seguro(origen_coords, destino_coords, franja = franja,
                                    factor_sesgo = f, k_alternativas = k_alternativas)
    for (r in rs) {
      candidatas[[length(candidatas) + 1]] <- r
      meta[[length(meta) + 1]] <- data.frame(duracion_min = r$duracion_min, exposicion = r$exposicion,
                                             transbordos = r$transbordos, caminata_min = r$caminata_min,
                                             factor = f, stringsAsFactors = FALSE)
    }
  }
  opciones <- do.call(rbind, meta)
  # Dominancia: j domina a i si es <= en ambos criterios y < en al menos uno
  n <- nrow(opciones)
  dominada <- logical(n)
  for (i in seq_len(n)) {
    dominada[i] <- any(
      opciones$duracion_min <= opciones$duracion_min[i] + 1e-9 &
        opciones$exposicion <= opciones$exposicion[i] + 1e-9 &
        (opciones$duracion_min < opciones$duracion_min[i] - 1e-9 |
           opciones$exposicion < opciones$exposicion[i] - 1e-9)
    )
  }
  # Quitar duplicados exactos (mismo tiempo y exposición) quedándose con el primero
  clave <- paste(round(opciones$duracion_min, 6), round(opciones$exposicion, 6))
  primero <- !duplicated(clave)
  keep <- which(!dominada & primero)
  keep <- keep[order(opciones$duracion_min[keep])]
  opciones <- opciones[keep, , drop = FALSE]
  opciones$id <- seq_len(nrow(opciones))
  list(opciones = opciones[, c("id", "duracion_min", "exposicion", "transbordos", "caminata_min", "factor")],
       rutas = candidatas[keep])
}

#' Coordenadas de cada paso del recorrido, para dibujarlo en el mapa.
#' @return data.frame con lat, lon, nombre y tipo (tipo de la arista que llega al punto)
puntos_ruta <- function(extremos, tipo, coords_od, topo) {
  nodos <- c(extremos[1, 1], extremos[, 2])
  tipo_llegada <- c(NA_character_, tipo)
  id <- sub("^(P:|L:[^|]*\\|)", "", nodos)
  ix <- match(id, topo$paradas$id_parada)
  lat <- topo$paradas$lat[ix]
  lon <- topo$paradas$lng[ix]
  nombre <- topo$paradas$nombre[ix]
  if (!is.null(coords_od)) {
    es_origen <- id == "ORIG"; es_destino <- id == "DEST"
    lat[es_origen] <- coords_od$origen$lat; lon[es_origen] <- coords_od$origen$lon
    lat[es_destino] <- coords_od$destino$lat; lon[es_destino] <- coords_od$destino$lon
    nombre[es_origen] <- "Origen"; nombre[es_destino] <- "Destino"
  }
  # Los estados (línea, parada) repiten la parada; se conserva solo el punto de la parada
  data.frame(lat = lat, lon = lon, nombre = nombre, tipo = tipo_llegada, stringsAsFactors = FALSE)
}

#' Convierte un camino (secuencia de aristas) en un resumen legible.
resumir_ruta <- function(g, ep, franja, factor_sesgo, coords_od = NULL) {
  tipo <- igraph::edge_attr(g, "tipo", ep)
  id_ruta <- igraph::edge_attr(g, "id_ruta", ep)
  tiempo <- igraph::edge_attr(g, "tiempo", ep)
  esp <- igraph::edge_attr(g, paste0("espera_", tolower(franja)), ep)
  sc <- igraph::edge_attr(g, "score", ep)
  topo <- cargar_topologia()
  nombres <- setNames(topo$paradas$nombre, topo$paradas$id_parada)
  extremos <- igraph::ends(g, ep)
  parada_de <- function(nodo) sub("^(P:|L:[^|]*\\|)", "", nodo)
  parada_nombre <- function(nodo) {
    id <- parada_de(nodo)
    out <- unname(nombres[id])
    out <- ifelse(is.na(out), id, out)   # si el nombre no existe, se muestra el id
    out[id == "ORIG"] <- "Origen"; out[id == "DEST"] <- "Destino"
    out
  }

  es_subida <- tipo == "subida"
  boardings <- sum(es_subida)
  espera_total <- sum(esp[es_subida] / 2, na.rm = TRUE)

  # Tramos legibles: una subida + viajes de la misma línea + bajada = un tramo de colectivo
  tramos <- list(); i <- 1
  while (i <= length(ep)) {
    if (tipo[i] == "subida") {
      linea <- id_ruta[i]; desde <- parada_nombre(extremos[i, 1]); j <- i + 1; paradas_viaje <- 0; minutos <- tiempo[i]
      while (j <= length(ep) && tipo[j] == "viaje" && id_ruta[j] == linea) {
        paradas_viaje <- paradas_viaje + 1; minutos <- minutos + tiempo[j]; j <- j + 1
      }
      hasta <- parada_nombre(extremos[j - 1, 2])
      tramos[[length(tramos) + 1]] <- data.frame(tipo = "colectivo", linea = linea, desde = desde, hasta = hasta,
                                                 paradas = paradas_viaje, minutos = minutos,
                                                 riesgo_medio = mean(sc[i:(j - 1)]), stringsAsFactors = FALSE)
      i <- j
    } else if (tipo[i] == "bajada") {
      i <- i + 1   # la bajada no es un tramo: el colectivo ya termina en esa parada
    } else {
      tramos[[length(tramos) + 1]] <- data.frame(
        tipo = ifelse(tipo[i] == "acceso", "a pie", ifelse(tipo[i] == "caminata", "transbordo a pie", tipo[i])),
        linea = NA_character_, desde = parada_nombre(extremos[i, 1]), hasta = parada_nombre(extremos[i, 2]),
        paradas = 0, minutos = tiempo[i], riesgo_medio = sc[i], stringsAsFactors = FALSE)
      i <- i + 1
    }
  }
  tramos <- do.call(rbind, tramos)
  caminata <- sum(tiempo[tipo %in% c("acceso", "caminata")])
  viaje_min <- sum(tiempo[tipo == "viaje"])
  bus <- tipo %in% c("viaje", "subida")
  list(
    costo = sum(pesos_aristas(g, franja, factor_sesgo)[ep]),
    duracion_min = viaje_min + espera_total + caminata,
    espera_min = espera_total,
    caminata_min = caminata,
    transbordos = max(0L, boardings - 1L),
    riesgo_medio = mean(sc[tipo %in% c("viaje", "subida")]),
    exposicion = sum(tiempo[tipo == "viaje"] * sc[tipo == "viaje"]),
    tramos = tramos,
    paradas = unique(c(parada_nombre(extremos[1, 1]), parada_nombre(extremos[, 2]))),
    puntos = puntos_ruta(extremos, tipo, coords_od, topo)
  )
}

#' Pide itinerarios a OTP.
#' @param origen,destino list(lat, lon)
#' @param fecha Date del servicio programado (ver FECHA_REFERENCIA en 03_base_transporte.R)
#' @param hora "HH:MM"
#' @param preferencia "rapida", "menos_transbordos", "menos_caminata" o "alternativas"
#' @return lista de itinerarios normalizados (ver `normalizar_itinerario`)
planificar_transporte <- function(origen, destino, fecha, hora = "08:00",
                                  preferencia = "rapida", n_itinerarios = 5) {
  if (!servidor_otp_disponible()) {
    stop("El planificador de transporte no está levantado. Iniciá OTP (ver GUIA_BETA.md).")
  }
  params <- list(
    fromPlace = sprintf("%.6f,%.6f", origen$lat, origen$lon),
    toPlace   = sprintf("%.6f,%.6f", destino$lat, destino$lon),
    date      = format(fecha, "%Y-%m-%d"),
    time      = hora,
    mode      = "TRANSIT,WALK",
    numItineraries = n_itinerarios,
    maxWalkDistance = 1000
  )
  if (preferencia == "menos_caminata") {
    params$maxWalkDistance <- 500
    params$walkReluctance <- 5
  }
  if (preferencia == "menos_transbordos") {
    params$transferPenalty <- 1800
  }

  r <- httr::GET(paste0(OTP_BASE, "/plan"), query = params, httr::timeout(120))
  if (httr::status_code(r) != 200) {
    stop("OTP respondió con error ", httr::status_code(r), ".")
  }
  j <- jsonlite::fromJSON(httr::content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (!is.null(j$error)) stop("OTP: ", j$error$msg %||% "error de planificación")
  its <- j$plan$itineraries
  if (length(its) == 0) return(list())
  lapply(its, normalizar_itinerario)
}

#' Convierte un itinerario de OTP en una lista limpia para la app.
normalizar_itinerario <- function(it) {
  tramos <- lapply(it$legs, function(leg) {
    geom <- decodificar_polilinea(leg$legGeometry$points)
    es_transporte <- leg$mode != "WALK"
    list(
      modo = leg$mode,
      modo_nombre = nombre_modo(leg$mode),
      linea = if (es_transporte) (leg$route %||% NA_character_) else NA_character_,
      destino_linea = if (es_transporte) (leg$headsign %||% NA_character_) else NA_character_,
      desde = leg$from$name,
      desde_lat = leg$from$lat, desde_lon = leg$from$lon,
      desde_parada_id = id_gtfs(leg$from$stopId$id),
      hasta = leg$to$name,
      hasta_lat = leg$to$lat, hasta_lon = leg$to$lon,
      salida = desde_epoch_ms(leg$startTime),
      llegada = desde_epoch_ms(leg$endTime),
      minutos = leg$duration / 60,
      distancia_m = leg$distance,
      paradas = if (es_transporte) length(leg$intermediateStops) else 0L,
      route_id = if (es_transporte) id_gtfs(leg$routeId) else NA_character_,
      feed = if (es_transporte) sub(":.*$", "", leg$routeId) else NA_character_,
      geometria = geom
    )
  })
  tramos_transporte <- Filter(function(t) t$modo != "WALK", tramos)
  geom_total <- do.call(rbind, lapply(tramos, `[[`, "geometria"))

  list(
    duracion_min = it$duration / 60,
    caminata_m = it$walkDistance,
    transbordos = max(0L, length(tramos_transporte) - 1L),
    espera_min = (it$waitingTime %||% 0) / 60,
    salida = desde_epoch_ms(it$startTime),
    llegada = desde_epoch_ms(it$endTime),
    tramos = tramos,
    geometria = geom_total
  ) -> itinerario

  # Exposición al riesgo de la opción (misma métrica que el optimizador)
  itinerario$geometria_sf <- if (nrow(geom_total) >= 2) {
    sf::st_sf(geometry = sf::st_sfc(sf::st_linestring(geom_total), crs = CRS_GEOGRAFICO))
  } else {
    NULL
  }
  itinerario
}

#' Resumen corto de un itinerario: "Caminar 300 m → Colectivo 60 → Subte A → Caminar".
resumen_itinerario <- function(it) {
  partes <- vapply(it$tramos, function(t) {
    if (t$modo == "WALK") {
      sprintf("Caminar %d m", round(t$distancia_m))
    } else {
      sprintf("%s %s (%d paradas)", t$modo_nombre, ifelse(is.na(t$linea), "", t$linea), t$paradas)
    }
  }, character(1))
  paste(partes, collapse = " → ")
}
