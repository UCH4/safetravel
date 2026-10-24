# ============================================================
# 03_base_transporte.R
# ETL del GTFS de colectivos de CABA/AMBA y construcción de la
# base de topología data/transporte.sqlite, con sesgo de riesgo.
#
# Pasos:
#   1. Carga del GTFS (data.table). Se descarta shapes.txt. De
#      stop_times.txt solo se usan 5 columnas y se filtran los viajes
#      del día de referencia (los demás se descartan en memoria).
#   2. Segmentos parada -> parada por viaje (tiempo de viaje real
#      programado entre paradas consecutivas).
#   3. Frecuencia por línea/parada en bloques horarios:
#      Mañana 06-12, Tarde 12-20, Noche 20-06 (espera media = minutos
#      del bloque / salidas del bloque).
#   4. Spatial join de cada parada con la grilla de riesgo
#      (data/grilla_riesgo.rds) -> score_riesgo (0-1).
#   5. Escritura de data/transporte.sqlite con SOLO tres tablas:
#      paradas_riesgo, lineas_recorridos, conectividad (con índices).
#
# Entrada: data/gtfs/colectivos-gtfs-2019-10-01.zip
#   (GTFS de colectivos filtrado al día de referencia; ver README.md).
#
# Ejecutar con: Rscript R/03_base_transporte.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")

suppressPackageStartupMessages({
  library(data.table)
  library(sf)
})

RUTA_GTFS_COLECTIVOS <- file.path(RUTA_DATOS, "gtfs", "colectivos-gtfs-2019-10-01.zip")
RUTA_DB_TRANSPORTE   <- file.path(RUTA_DATOS, "transporte.sqlite")
FECHA_REFERENCIA_COL <- as.Date("2019-10-01")

# Bloques horarios: nombre, desde (min. desde medianoche), hasta, duración en minutos.
# La franja Noche cruza medianoche: 20:00 a 06:00 (se trata con % 1440).
FRANJAS <- data.table(
  franja = c("Manana", "Tarde", "Noche"),
  desde  = c(6 * 60, 12 * 60, 20 * 60),
  hasta  = c(12 * 60, 20 * 60, 30 * 60),   # 30 * 60 = 06:00 del día siguiente
  minutos = c(6 * 60, 8 * 60, 10 * 60)
)

#' Convierte horas GTFS "HH:MM:SS" (pueden superar 24:00) a minutos desde medianoche.
#' Vectorizado: es el paso más costoso con 9–31 millones de filas.
hora_a_minutos <- function(x) {
  h <- as.integer(sub(":.*$", "", x))
  m <- as.integer(sub("^[0-9]+:([0-9]+):.*$", "\\1", x))
  s <- as.integer(sub("^.*:", "", x))
  h * 60 + m + s / 60
}

#' Asigna la franja horaria a minutos desde medianoche (0–1800, para viajes que cruzan la noche).
franja_de <- function(minutos) {
  t <- minutos %% 1440
  t <- ifelse(t < 360, t + 1440, t)   # 00:00-05:59 pertenecen a la Noche del día anterior
  out <- rep(NA_character_, length(t))
  for (i in seq_len(nrow(FRANJAS))) {
    out[t >= FRANJAS$desde[i] & t < FRANJAS$hasta[i]] <- FRANJAS$franja[i]
  }
  out
}

#' Lee una tabla de un GTFS (ZIP) sin descomprimir a disco.
leer_gtfs_tabla <- function(zip, archivo, select = NULL, colClasses = NULL) {
  fread(cmd = paste("unzip -p", shQuote(zip), archivo), select = select,
        colClasses = colClasses, showProgress = FALSE, encoding = "UTF-8")
}

#' Servicios (service_id) activos en la fecha de referencia, según calendar_dates.
servicios_en_fecha <- function(zip, fecha) {
  cd <- leer_gtfs_tabla(zip, "calendar_dates.txt", colClasses = c(service_id = "character"))
  f <- as.integer(format(fecha, "%Y%m%d"))
  cd[date == f & exception_type == 1, unique(service_id)]
}

#' ETL del GTFS de colectivos: devuelve las tres tablas ya optimizadas (sin escribir).
etl_colectivos <- function(zip = RUTA_GTFS_COLECTIVOS, fecha = FECHA_REFERENCIA_COL,
                           grilla = readRDS(file.path(RUTA_DATOS, "grilla_riesgo.rds"))) {
  message("1/5 Servicios activos el ", fecha, "...")
  servicios <- servicios_en_fecha(zip, fecha)
  if (length(servicios) == 0) stop("Ningún servicio activo en la fecha ", fecha)

  message("2/5 Viajes y stop_times del día (sin shapes.txt)...")
  viajes_hdr <- names(leer_gtfs_tabla(zip, "trips.txt")[0])
  cols_viajes <- intersect(c("route_id", "service_id", "trip_id", "trip_headsign"), viajes_hdr)
  viajes <- leer_gtfs_tabla(zip, "trips.txt", select = cols_viajes,
                            colClasses = c(route_id = "character", service_id = "character",
                                           trip_id = "character"))
  viajes <- viajes[service_id %in% servicios]
  if (!"trip_headsign" %in% names(viajes)) viajes[, trip_headsign := NA_character_]

  st <- leer_gtfs_tabla(zip, "stop_times.txt",
                        select = c("trip_id", "stop_id", "stop_sequence", "arrival_time", "departure_time"),
                        colClasses = c(trip_id = "character", stop_id = "character"))
  st <- st[trip_id %in% viajes$trip_id]
  setorder(st, trip_id, stop_sequence)
  st[, min_arr := hora_a_minutos(arrival_time)]
  st[, min_dep := hora_a_minutos(departure_time)]
  st[, c("arrival_time", "departure_time") := NULL]

  message("3/5 Segmentos parada -> parada y frecuencias por franja...")
  st[, `:=`(stop_sig = shift(stop_id, type = "lead"), arr_sig = shift(min_arr, type = "lead")),
     by = trip_id]
  seg <- st[!is.na(stop_sig), .(trip_id, from = stop_id, to = stop_sig,
                                dep = min_dep, t = arr_sig - min_dep)]
  rm(st); gc(verbose = FALSE)
  # Descarta tramos imposibles entre paradas consecutivas (errores del origen): menos de 0 o más de 30 min.
  seg <- seg[t > 0 & t <= 30]
  seg <- merge(seg, viajes[, .(trip_id, route_id, trip_headsign)], by = "trip_id")
  seg[, franja := franja_de(dep)]
  seg <- seg[!is.na(franja)]

  # Tiempo de viaje por tramo: mediana de los viajes del día
  tramos <- seg[, .(tiempo_min = median(t), salidas = .N), by = .(route_id, from, to)]

  # Salidas por línea/parada/franja -> espera media = minutos de la franja / salidas
  salidas_franja <- seg[, .N, by = .(route_id, from, franja)]
  espera <- dcast(salidas_franja, route_id + from ~ franja, value.var = "N", fill = 0)
  for (i in seq_len(nrow(FRANJAS))) {
    f <- FRANJAS$franja[i]
    col_salidas <- espera[[f]]
    nombre <- paste0("espera_", tolower(f), "_min")
    espera[, (nombre) := ifelse(col_salidas > 0, FRANJAS$minutos[i] / col_salidas, NA_real_)]
  }
  espera <- espera[, c("route_id", "from", grep("^espera_", names(espera), value = TRUE)), with = FALSE]
  conectividad <- merge(tramos, espera, by = c("route_id", "from"), all.x = TRUE)
  conectividad[, `:=`(from = as.character(from), to = as.character(to), route_id = as.character(route_id))]
  setnames(conectividad, c("from", "to", "route_id", "tiempo_min"),
           c("id_parada_origen", "id_parada_destino", "id_ruta", "tiempo_estimado_entre_paradas"))
  conectividad[, salidas := NULL]

  message("4/5 Paradas, líneas y spatial join con la grilla de riesgo...")
  paradas_gtfs <- leer_gtfs_tabla(zip, "stops.txt",
                                  select = c("stop_id", "stop_name", "stop_lat", "stop_lon"),
                                  colClasses = c(stop_id = "character"))
  usadas <- unique(c(conectividad$id_parada_origen, conectividad$id_parada_destino))
  paradas_gtfs <- paradas_gtfs[stop_id %in% usadas]
  pts <- st_as_sf(paradas_gtfs, coords = c("stop_lon", "stop_lat"), crs = CRS_GEOGRAFICO, remove = FALSE)
  pts <- st_transform(pts, st_crs(grilla))
  cruce <- st_join(pts, grilla[, "riesgo"], join = st_intersects, left = TRUE)
  cruce <- cruce[!duplicated(cruce$stop_id), ]
  paradas_riesgo <- data.table(
    id_parada = cruce$stop_id,
    nombre = cruce$stop_name,
    lat = cruce$stop_lat,
    lng = cruce$stop_lon,
    score_riesgo = cruce$riesgo   # NA si la parada está fuera de la grilla (fuera de CABA)
  )

  routes <- leer_gtfs_tabla(zip, "routes.txt",
                            select = c("route_id", "route_short_name", "route_long_name"),
                            colClasses = c(route_id = "character"))
  routes <- routes[route_id %in% conectividad$id_ruta]
  ramal <- viajes[, .N, by = .(route_id, trip_headsign)][order(-N), .SD[1], by = route_id]
  lineas_recorridos <- merge(routes, ramal[, .(route_id, ramal = trip_headsign)], by = "route_id", all.x = TRUE)
  lineas_recorridos <- lineas_recorridos[, .(
    id_ruta = route_id,
    nombre_linea = route_short_name,
    ramal = fifelse(is.na(ramal) | ramal == "", route_long_name, ramal)
  )]

  message("5/5 Listo: ", nrow(paradas_riesgo), " paradas, ", nrow(lineas_recorridos),
          " líneas, ", nrow(conectividad), " tramos.")
  list(paradas_riesgo = paradas_riesgo, lineas_recorridos = lineas_recorridos,
       conectividad = conectividad)
}

#' Escribe data/transporte.sqlite con SOLO las tres tablas y sus índices.
escribir_base_transporte <- function(tablas, ruta_db = RUTA_DB_TRANSPORTE) {
  if (!requireNamespace("RSQLite", quietly = TRUE)) stop("Falta el paquete RSQLite.")
  if (file.exists(ruta_db)) file.remove(ruta_db)
  con <- DBI::dbConnect(RSQLite::SQLite(), ruta_db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbWriteTable(con, "paradas_riesgo", as.data.frame(tablas$paradas_riesgo))
  DBI::dbWriteTable(con, "lineas_recorridos", as.data.frame(tablas$lineas_recorridos))
  DBI::dbWriteTable(con, "conectividad", as.data.frame(tablas$conectividad))
  DBI::dbExecute(con, "CREATE UNIQUE INDEX idx_paradas_id ON paradas_riesgo(id_parada)")
  DBI::dbExecute(con, "CREATE INDEX idx_paradas_geo ON paradas_riesgo(lat, lng)")
  DBI::dbExecute(con, "CREATE UNIQUE INDEX idx_lineas_id ON lineas_recorridos(id_ruta)")
  DBI::dbExecute(con, "CREATE INDEX idx_con_origen ON conectividad(id_parada_origen)")
  DBI::dbExecute(con, "CREATE INDEX idx_con_destino ON conectividad(id_parada_destino)")
  DBI::dbExecute(con, "CREATE INDEX idx_con_ruta ON conectividad(id_ruta)")
  message("Base escrita en ", ruta_db, " (", round(file.size(ruta_db) / 1e6, 1), " MB).")
  invisible(ruta_db)
}

if (sys.nframe() == 0) {
  tablas <- etl_colectivos()
  escribir_base_transporte(tablas)
}
