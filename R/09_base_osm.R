# ============================================================
# 09_base_osm.R
# Base de transporte construida desde OpenStreetMap (relaciones route=bus de CABA,
# snapshot de octubre de 2026), con el mismo esquema que data/transporte.sqlite.
#
#   - Paradas y orden de cada línea: miembros "stop" (o "platform" si no hay) de cada
#     relación, en el orden de la relación. Recorridos actuales.
#   - Tiempo entre paradas: distancia en línea recta / VELOCIDAD_BUS_OSM_KMH.
#     OSM no tiene horarios: es una estimación.
#   - Espera (intervalo entre salidas) por franja: tomada de la base GTFS 2019 de la
#     misma línea (mismo nombre). Si no existe, de la línea de igual número con otro
#     ramal, y si tampoco, INTERVALO_DEFAULT_MIN. Es una estimación marcada como tal.
#   - Score de riesgo: percentil de la grilla en el punto de cada parada (igual que 03).
#
# Entrada: data/raw/osm_bus_caba.json (Overpass, route=bus en CABA)
# Salida:  data/transporte_osm.sqlite
# Ejecutar con: Rscript R/09_base_osm.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("transporte.R")) "transporte.R" else "R/transporte.R")
source(if (file.exists("03_base_transporte.R")) "03_base_transporte.R" else "R/03_base_transporte.R")

RUTA_OSM_JSON <- file.path(RUTA_DATOS, "raw", "osm_bus_caba.json")
RUTA_DB_OSM <- file.path(RUTA_DATOS, "transporte_osm.sqlite")
VELOCIDAD_BUS_OSM_KMH <- 15
INTERVALO_DEFAULT_MIN <- 20

#' Coordenadas de un miembro de la relación: nodo directo o centroide del camino.
coordenadas_miembro <- function(m, nodos, caminos) {
  if (m$type == "node") {
    n <- nodos[[as.character(m$ref)]]
    if (is.null(n)) return(NULL)
    return(c(lat = n$lat, lon = n$lon))
  }
  cam <- caminos[[as.character(m$ref)]]
  if (is.null(cam)) return(NULL)
  pts <- do.call(rbind, lapply(cam$nodes, function(id) {
    n <- nodos[[as.character(id)]]
    if (is.null(n)) return(NULL)
    c(lat = n$lat, lon = n$lon)
  }))
  if (is.null(pts) || nrow(pts) == 0) return(NULL)
  colMeans(pts)
}

#' Lee el JSON de Overpass y devuelve paradas por línea: lista(id_ruta, ref, ramal, paradas).
leer_relaciones_osm <- function(ruta = RUTA_OSM_JSON) {
  if (!file.exists(ruta)) stop("No existe ", ruta, ". Descargar con la consulta de Overpass (ver README).")
  e <- jsonlite::fromJSON(ruta, simplifyVector = FALSE)$elements
  tipos <- vapply(e, function(x) x$type, "")
  nodos <- setNames(e[tipos == "node"], vapply(e[tipos == "node"], function(x) as.character(x$id), ""))
  caminos <- setNames(e[tipos == "way"], vapply(e[tipos == "way"], function(x) as.character(x$id), ""))
  rels <- e[tipos == "relation"]

  lapply(rels, function(r) {
    if (is.null(r$tags$ref)) return(NULL)
    miembros <- r$members
    es_parada <- vapply(miembros, function(m) grepl("^stop", m$role %||% ""), TRUE)
    es_anden <- vapply(miembros, function(m) grepl("platform", m$role %||% ""), TRUE)
    seleccion <- if (any(es_parada)) miembros[es_parada] else miembros[es_anden]
    paradas <- lapply(seleccion, function(m) {
      xy <- coordenadas_miembro(m, nodos, caminos)
      if (is.null(xy)) return(NULL)
      nombre <- NA_character_
      if (m$type == "node" && !is.null(nodos[[as.character(m$ref)]]$tags$name)) nombre <- nodos[[as.character(m$ref)]]$tags$name
      if (m$type == "way" && !is.null(caminos[[as.character(m$ref)]]$tags$name)) nombre <- caminos[[as.character(m$ref)]]$tags$name
      list(id = paste0(if (m$type == "node") "n" else "w", m$ref), nombre = nombre, lat = xy[["lat"]], lon = xy[["lon"]])
    })
    paradas <- Filter(Negate(is.null), paradas)
    if (length(paradas) < 2) return(NULL)
    list(id_ruta = as.character(r$id), ref = r$tags$ref, ramal = r$tags$to %||% NA_character_,
         paradas = paradas)
  }) |> Filter(f = Negate(is.null))
}

#' Intervalo (minutos entre salidas) por franja, de la base GTFS 2019 de la misma línea.
intervalos_2019 <- function(ref) {
  topo <- cargar_topologia()
  lin <- topo$lineas
  numero <- sub("^([0-9]+).*$", "\\1", ref)
  candidatas <- lin$id_ruta[lin$nombre_linea == ref]
  if (length(candidatas) == 0) {
    candidatas <- lin$id_ruta[sub("^([0-9]+).*$", "\\1", lin$nombre_linea) == numero]
  }
  if (length(candidatas) == 0) {
    return(setNames(rep(INTERVALO_DEFAULT_MIN, 3), c("espera_manana_min", "espera_tarde_min", "espera_noche_min")))
  }
  con <- topo$conectividad[topo$conectividad$id_ruta %in% candidatas]
  setNames(c(median(con$espera_manana_min, na.rm = TRUE), median(con$espera_tarde_min, na.rm = TRUE),
             median(con$espera_noche_min, na.rm = TRUE)),
           c("espera_manana_min", "espera_tarde_min", "espera_noche_min"))
}

if (sys.nframe() == 0) {
  message("Leyendo relaciones de OSM...")
  lineas <- leer_relaciones_osm()
  message("Líneas con paradas: ", length(lineas))

  # Paradas únicas (la misma parada puede estar en varias líneas)
  todas <- do.call(rbind, lapply(lineas, function(l) do.call(rbind, lapply(l$paradas, function(p)
    data.frame(id_parada = p$id, nombre = p$nombre, lat = p$lat, lng = p$lon, stringsAsFactors = FALSE)))))
  paradas <- todas[!duplicated(todas$id_parada), ]
  paradas$nombre[is.na(paradas$nombre)] <- paste("Parada", paradas$id_parada[is.na(paradas$nombre)])

  # Score de riesgo: percentil de la grilla en el punto de cada parada
  grilla <- readRDS(file.path(RUTA_DATOS, "grilla_riesgo.rds"))
  pts <- sf::st_transform(sf::st_as_sf(paradas, coords = c("lng", "lat"), crs = CRS_GEOGRAFICO, remove = FALSE),
                          sf::st_crs(grilla))
  cruce <- sf::st_join(pts, grilla[, "riesgo"], join = sf::st_intersects, left = TRUE)
  cruce <- cruce[!duplicated(cruce$id_parada), ]
  paradas_riesgo <- data.frame(id_parada = cruce$id_parada, nombre = cruce$nombre, lat = cruce$lat,
                               lng = cruce$lng,
                               score_riesgo = ecdf(grilla$riesgo)(cruce$riesgo), stringsAsFactors = FALSE)

  # Líneas y tramos: consecutivos dentro de cada relación
  lineas_recorridos <- data.frame(id_ruta = vapply(lineas, `[[`, "", "id_ruta"),
                                  nombre_linea = vapply(lineas, `[[`, "", "ref"),
                                  ramal = vapply(lineas, function(l) l$ramal %||% NA_character_, ""),
                                  stringsAsFactors = FALSE)
  tramos <- do.call(rbind, lapply(lineas, function(l) {
    ids <- vapply(l$paradas, `[[`, "", "id")
    if (length(ids) < 2) return(NULL)
    lat <- vapply(l$paradas, `[[`, 0, "lat"); lon <- vapply(l$paradas, `[[`, 0, "lon")
    d_m <- distancias_m(lat[-length(lat)], lon[-length(lon)], lat[-1], lon[-1])
    esperas <- intervalos_2019(l$ref)
    data.frame(id_parada_origen = ids[-length(ids)], id_parada_destino = ids[-1],
               id_ruta = l$id_ruta, tiempo_estimado_entre_paradas = d_m / (VELOCIDAD_BUS_OSM_KMH * 1000 / 60),
               espera_manana_min = esperas[["espera_manana_min"]], espera_tarde_min = esperas[["espera_tarde_min"]],
               espera_noche_min = esperas[["espera_noche_min"]], stringsAsFactors = FALSE)
  }))
  tramos <- tramos[tramos$id_parada_origen != tramos$id_parada_destino, ]

  escribir_base_transporte(list(paradas_riesgo = paradas_riesgo, lineas_recorridos = lineas_recorridos,
                                conectividad = as.data.table(tramos)), ruta_db = RUTA_DB_OSM)
  message("Base OSM: ", nrow(paradas_riesgo), " paradas, ", nrow(lineas_recorridos), " líneas, ",
          nrow(tramos), " tramos.")
}
