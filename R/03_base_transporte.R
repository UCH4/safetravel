# ============================================================
# 03_base_transporte.R
# Construye la base de datos local de transporte público
# (data/transporte.sqlite) a partir de los GTFS estáticos
# descargados de datos abiertos.
#
# Fuentes (ver data/otp/graph/):
#   - colectivos-gtfs.zip  BA Data (CABA), calendario 2019-09 a 2019-12
#   - subte-gtfs.zip       SBASE (CABA), calendario 2014 a 2021
#   - trenes-gtfs.zip      Trenes Argentinos (BA Data), vigencia 2020-02 a 2020-04
#
# Cada fuente conserva su fecha de vigencia. Nada se presenta
# como "tiempo real": son horarios programados.
#
# Ejecutar con: Rscript R/03_base_transporte.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")

RUTA_GTFS <- file.path(RUTA_DATOS, "otp", "graph")
RUTA_DB_TRANSPORTE <- file.path(RUTA_DATOS, "transporte.sqlite")

# Fecha de referencia por modo: un día hábil dentro del calendario de cada feed.
# Colectivos y subte: 1-oct-2019. Trenes: 5-feb-2020 (su feed es de 2020).
# No existe una fecha común a los tres feeds.
FECHA_REFERENCIA <- c(colectivos = as.Date("2019-10-01"),
                      subte = as.Date("2019-10-01"),
                      trenes = as.Date("2020-02-05"))

# Ventanas de hora pico para estimar frecuencia (minutos entre servicios)
PICO_MANIANA <- c(7 * 60, 10 * 60)
PICO_TARDE   <- c(17 * 60, 20 * 60)

#' Lee un archivo de un GTFS (ZIP) sin descomprimirlo en disco.
leer_gtfs <- function(zip, archivo, select = NULL) {
  ruta <- file.path(RUTA_GTFS, zip)
  data.table::fread(cmd = paste("unzip -p", shQuote(ruta), archivo),
                    select = select, showProgress = FALSE, encoding = "UTF-8")
}

#' Convierte "HH:MM:SS" (puede superar 24:00) a minutos desde medianoche.
hora_a_minutos <- function(hora) {
  p <- strsplit(hora, ":", fixed = TRUE)
  vapply(p, function(x) as.numeric(x[1]) * 60 + as.numeric(x[2]) + as.numeric(x[3]) / 60, numeric(1))
}

#' Service_id activos en una fecha, según calendar.txt y calendar_dates.txt.
servicios_activos <- function(zip, fecha) {
  dias <- c("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
  dia <- dias[as.POSIXlt(fecha)$wday + 1]
  f <- format(fecha, "%Y%m%d")
  activos <- character(0)

  cal <- tryCatch(leer_gtfs(zip, "calendar.txt"), error = function(e) NULL)
  if (!is.null(cal) && nrow(cal) > 0) {
    cal$service_id <- as.character(cal$service_id)
    ok <- cal[[dia]] == 1 & cal$start_date <= as.numeric(f) & cal$end_date >= as.numeric(f)
    activos <- cal$service_id[ok]
  }
  cd <- tryCatch(leer_gtfs(zip, "calendar_dates.txt"), error = function(e) NULL)
  if (!is.null(cd) && nrow(cd) > 0) {
    cd$service_id <- as.character(cd$service_id)
    en_fecha <- cd[cd$date == as.numeric(f), ]
    activos <- union(setdiff(activos, en_fecha$service_id[en_fecha$exception_type == 2]),
                     en_fecha$service_id[en_fecha$exception_type == 1])
  }
  activos
}

#' Lee los datos básicos de una fuente GTFS y los devuelve como listas de tablas.
leer_feed <- function(modo, zip) {
  feed_info <- tryCatch(leer_gtfs(zip, "feed_info.txt"), error = function(e) NULL)
  cd <- tryCatch(leer_gtfs(zip, "calendar_dates.txt"), error = function(e) NULL)
  vigencia <- if (!is.null(feed_info) && all(c("feed_start_date", "feed_end_date") %in% names(feed_info))) {
    paste(feed_info$feed_start_date[1], feed_info$feed_end_date[1])
  } else if (!is.null(cd) && nrow(cd) > 0) {
    paste(min(cd$date), max(cd$date))
  } else {
    NA_character_
  }
  paradas <- leer_gtfs(zip, "stops.txt", select = c("stop_id", "stop_name", "stop_lat", "stop_lon"))
  rutas   <- leer_gtfs(zip, "routes.txt")
  viajes  <- leer_gtfs(zip, "trips.txt")

  list(
    feed = data.frame(modo = modo, archivo = zip, vigencia = vigencia, stringsAsFactors = FALSE),
    paradas = data.frame(modo = modo, stop_id = as.character(paradas$stop_id),
                         nombre = paradas$stop_name, lat = paradas$stop_lat, lon = paradas$stop_lon,
                         stringsAsFactors = FALSE),
    lineas = data.frame(modo = modo, route_id = as.character(rutas$route_id),
                        nombre_corto = if ("route_short_name" %in% names(rutas)) rutas$route_short_name else NA,
                        nombre_largo = if ("route_long_name" %in% names(rutas)) rutas$route_long_name else NA,
                        stringsAsFactors = FALSE),
    viajes = data.frame(modo = modo, trip_id = as.character(viajes$trip_id),
                        route_id = as.character(viajes$route_id),
                        service_id = as.character(viajes$service_id),
                        sentido = if ("trip_headsign" %in% names(viajes)) viajes$trip_headsign else NA_character_, stringsAsFactors = FALSE)
  )
}

#' Frecuencia por parada y línea para el día de referencia.
#' Para cada línea y parada: viajes del día y minutos promedio entre servicios en hora pico.
calcular_frecuencias <- function(modo, zip, servicios) {
  st <- leer_gtfs(zip, "stop_times.txt",
                  select = c("trip_id", "stop_id", "stop_sequence", "departure_time"))
  viajes <- leer_gtfs(zip, "trips.txt", select = c("route_id", "service_id", "trip_id"))
  viajes$trip_id <- as.character(viajes$trip_id)
  viajes <- viajes[as.character(viajes$service_id) %in% servicios, ]
  st$trip_id <- as.character(st$trip_id)
  st <- st[st$trip_id %in% viajes$trip_id, ]
  st <- merge(st, viajes[, c("trip_id", "route_id")], by = "trip_id")
  st$min <- hora_a_minutos(st$departure_time)

  en_pico <- (st$min >= PICO_MANIANA[1] & st$min < PICO_MANIANA[2]) |
             (st$min >= PICO_TARDE[1] & st$min < PICO_TARDE[2])
  agg <- data.frame(
    modo = modo,
    route_id = as.character(st$route_id),
    stop_id = as.character(st$stop_id),
    trip_id = st$trip_id,
    en_pico = en_pico,
    stringsAsFactors = FALSE
  )
  # Un viaje cuenta una sola vez por parada
  agg <- agg[!duplicated(agg[, c("trip_id", "stop_id")]), ]
  res <- do.call(rbind, lapply(split(agg, list(agg$route_id, agg$stop_id), drop = TRUE), function(d) {
    pico <- sum(d$en_pico)
    data.frame(modo = modo, route_id = d$route_id[1], stop_id = d$stop_id[1],
               viajes_dia = nrow(d), viajes_pico = pico,
               espera_pico_min = if (pico > 0) round((PICO_MANIANA[2] - PICO_MANIANA[1] +
                                                       PICO_TARDE[2] - PICO_TARDE[1]) / pico, 1) else NA_real_,
               stringsAsFactors = FALSE)
  }))
  res
}

#' Construye data/transporte.sqlite con todas las fuentes.
construir_base_transporte <- function(ruta_db = RUTA_DB_TRANSPORTE) {
  if (!requireNamespace("RSQLite", quietly = TRUE)) stop("Falta el paquete RSQLite.")
  fuentes <- c(colectivos = "colectivos-gtfs.zip", subte = "subte-gtfs.zip", trenes = "trenes-gtfs.zip")

  con <- DBI::dbConnect(RSQLite::SQLite(), ruta_db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  for (t in c("feeds", "paradas", "lineas", "viajes", "frecuencias")) {
    if (DBI::dbExistsTable(con, t)) DBI::dbRemoveTable(con, t)
  }

  feeds <- list(); paradas <- list(); lineas <- list(); viajes <- list(); frec <- list()
  for (modo in names(fuentes)) {
    message("Leyendo ", modo, " (", fuentes[[modo]], ")...")
    f <- leer_feed(modo, fuentes[[modo]])
    fecha <- FECHA_REFERENCIA[[modo]]
    servicios <- servicios_activos(fuentes[[modo]], fecha)
    f$feed$servicios_referencia <- length(servicios)
    f$feed$fecha_referencia <- as.character(fecha)
    feeds[[modo]] <- f$feed; paradas[[modo]] <- f$paradas; lineas[[modo]] <- f$lineas; viajes[[modo]] <- f$viajes
    if (length(servicios) > 0) {
      frec[[modo]] <- calcular_frecuencias(modo, fuentes[[modo]], servicios)
    }
  }

  DBI::dbWriteTable(con, "feeds", do.call(rbind, feeds))
  DBI::dbWriteTable(con, "paradas", do.call(rbind, paradas))
  DBI::dbWriteTable(con, "lineas", do.call(rbind, lineas))
  DBI::dbWriteTable(con, "viajes", do.call(rbind, viajes))
  DBI::dbWriteTable(con, "frecuencias", do.call(rbind, frec))
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_frec_parada ON frecuencias(stop_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_paradas_nombre ON paradas(nombre)")
  message("Base creada en ", ruta_db)
  invisible(ruta_db)
}

if (sys.nframe() == 0) construir_base_transporte()
