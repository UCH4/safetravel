# ============================================================
# transporte.R
# Planificación de viajes en transporte público (colectivo, subte,
# tren y tramos a pie) con OpenTripPlanner (OTP), y consulta de
# frecuencias en data/transporte.sqlite.
#
# Requisitos: servidor OTP local en OTP_URL (ver GUIA_BETA.md).
# Todos los horarios son PROGRAMADOS (GTFS), no en tiempo real.
# ============================================================

OTP_BASE <- "http://localhost:8080/otp/routers/default"
TZ_CABA <- "America/Argentina/Buenos_Aires"
RUTA_DB_TRANSPORTE_APP <- if (file.exists(file.path(RUTA_DATOS, "transporte.sqlite"))) {
  file.path(RUTA_DATOS, "transporte.sqlite")
} else {
  NA_character_
}

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

#' Consulta espera/frecuencia programada de una línea en una parada (desde la base).
#' @return data.frame con viajes_pico y espera_pico_min, o NULL si no hay datos.
consultar_espera <- function(modo_gtfs, route_id, stop_id) {
  if (is.na(RUTA_DB_TRANSPORTE_APP) || !requireNamespace("RSQLite", quietly = TRUE)) return(NULL)
  con <- DBI::dbConnect(RSQLite::SQLite(), RUTA_DB_TRANSPORTE_APP)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbGetQuery(con, "SELECT viajes_pico, espera_pico_min FROM frecuencias
                        WHERE modo = ? AND route_id = ? AND stop_id = ? LIMIT 1",
                  params = list(modo_gtfs, route_id, stop_id))
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
