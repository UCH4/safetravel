# ============================================================
# 08_benchmark_r5r.R
# Compara, en los mismos pares de CABA, nuestro ruteo de colectivos
# (calcular_colectivo_seguro, GTFS 2019 + trazados RMBA) contra r5r
# (red OSM recortada a AMBA + GTFS 2019-10-01).
#
# Métricas por par: la opción más rápida y la más segura de cada método.
# Exposición con la misma escala que el ruteo: tiempo de viaje en colectivo
# x score de riesgo (percentil de la grilla) de cada parada de subida y bajada.
# En r5r el riesgo se estima con las paradas de inicio y fin de cada tramo de bus.
#
# Salida: data/benchmark_r5r.csv
# Requiere: JAVA_HOME apuntando a JDK 21 y data/r5r/ (red construida con setup_r5).
# Ejecutar con: Rscript R/08_benchmark_r5r.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("transporte.R")) "transporte.R" else "R/transporte.R")

RUTA_BENCH <- file.path(RUTA_DATOS, "benchmark_r5r.csv")
DIR_R5R <- file.path(RUTA_DATOS, "r5r")
N_PARES_BENCH <- 30
SEMILLA_BENCH <- 2026
FECHA_R5R <- as.POSIXct("2019-10-01 14:00:00", tz = "America/Argentina/Buenos_Aires")

#' Pares de centroides de la grilla separados entre 2 y 8 km.
pares_benchmark <- function(n = N_PARES_BENCH, semilla = SEMILLA_BENCH) {
  grilla <- readRDS(file.path(RUTA_DATOS, "grilla_riesgo.rds"))
  c_ll <- sf::st_coordinates(sf::st_transform(sf::st_centroid(grilla), CRS_GEOGRAFICO))
  set.seed(semilla)
  pares <- list()
  while (length(pares) < n) {
    i <- sample(nrow(c_ll), 1); j <- sample(nrow(c_ll), 1)
    d <- distancias_m(c_ll[i, 2], c_ll[i, 1], c_ll[j, 2], c_ll[j, 1])
    if (d >= 2000 && d <= 8000) {
      pares[[length(pares) + 1]] <- list(origen = list(lat = c_ll[i, 2], lon = c_ll[i, 1]),
                                         destino = list(lat = c_ll[j, 2], lon = c_ll[j, 1]),
                                         distancia_m = d)
    }
  }
  pares
}

#' Score de riesgo (percentil de la grilla) de un punto. Fuera de la grilla: neutro.
score_en_puntos <- function(lat, lon, grilla_riesgo_pts, grilla_vals) {
  pts <- sf::st_as_sf(data.frame(lon = lon, lat = lat), coords = c("lon", "lat"), crs = CRS_GEOGRAFICO)
  pts <- sf::st_transform(pts, sf::st_crs(grilla_riesgo_pts))
  idx <- sf::st_nearest_feature(pts, grilla_riesgo_pts)
  dist <- as.numeric(sf::st_distance(pts, grilla_riesgo_pts[idx, ], by_element = TRUE))
  valor <- grilla_riesgo_pts$riesgo[idx]
  valor[dist > TAMANO_CELDA_M] <- NA
  ifelse(is.na(valor), SCORE_NEUTRO_FUERA_CABA, ecdf(grilla_vals)(valor))
}

#' Resumen de nuestro ruteo para un par (factor 0 = rápida, factor 1 = segura).
ruteo_propio <- function(par) {
  rap <- tryCatch(calcular_colectivo_seguro(par$origen, par$destino, franja = "Tarde", factor_sesgo = 0, k_alternativas = 1)[[1]], error = function(e) NULL)
  seg <- tryCatch(calcular_colectivo_seguro(par$origen, par$destino, franja = "Tarde", factor_sesgo = 1, k_alternativas = 1)[[1]], error = function(e) NULL)
  list(rapida = if (is.null(rap)) c(NA, NA) else c(rap$duracion_min, rap$exposicion),
       segura = if (is.null(seg)) c(NA, NA) else c(seg$duracion_min, seg$exposicion))
}

#' Resumen de r5r para un par: opción más rápida y más segura entre las que devuelve.
ruteo_r5r <- function(core, par, grilla_riesgo_pts, grilla_vals) {
  it <- tryCatch(as.data.frame(r5r::detailed_itineraries(
    core,
    origins = data.frame(id = "o", lon = par$origen$lon, lat = par$origen$lat),
    destinations = data.frame(id = "d", lon = par$destino$lon, lat = par$destino$lat),
    mode = c("WALK", "TRANSIT"), departure_datetime = FECHA_R5R,
    max_walk_time = 20, max_trip_duration = 120, shortest_path = FALSE, verbose = FALSE)),
    error = function(e) { message("  r5r: ", conditionMessage(e)); NULL })
  if (is.null(it) || nrow(it) == 0) return(list(n = 0, rapida = c(NA, NA), segura = c(NA, NA)))

  opciones <- lapply(split(it, it$option), function(x) {
    bus <- x[x$mode == "BUS", ]
    dur <- sum(x$segment_duration)
    expo <- 0
    if (nrow(bus) > 0) {
      sc_ini <- score_en_puntos(bus$from_lat, bus$from_lon, grilla_riesgo_pts, grilla_vals)
      sc_fin <- score_en_puntos(bus$to_lat, bus$to_lon, grilla_riesgo_pts, grilla_vals)
      expo <- sum(bus$segment_duration * (sc_ini + sc_fin) / 2)
    }
    c(dur, expo)
  })
  m <- do.call(rbind, opciones)
  list(n = nrow(m), rapida = m[which.min(m[, 1]), ], segura = m[which.min(m[, 2]), ])
}

if (sys.nframe() == 0) {
  options(java.parameters = "-Xmx12G")
  if (!requireNamespace("r5r", quietly = TRUE)) stop("Falta r5r. Ver README (JDK 21).")
  grilla <- readRDS(file.path(RUTA_DATOS, "grilla_riesgo.rds"))
  grilla_vals <- grilla$riesgo
  grilla_pts <- sf::st_transform(sf::st_centroid(grilla), sf::st_crs(grilla))
  core <- r5r::setup_r5(data_path = DIR_R5R, verbose = FALSE)

  pares <- pares_benchmark()
  filas <- lapply(seq_along(pares), function(k) {
    message("Par ", k, " de ", length(pares))
    p <- pares[[k]]
    prop <- ruteo_propio(p)
    r <- ruteo_r5r(core, p, grilla_pts, grilla_vals)
    data.frame(par = k, distancia_m = round(p$distancia_m),
               propio_rapida_min = prop$rapida[1], propio_rapida_exp = prop$rapida[2],
               propio_segura_min = prop$segura[1], propio_segura_exp = prop$segura[2],
               r5r_n_opciones = r$n,
               r5r_rapida_min = r$rapida[1], r5r_rapida_exp = r$rapida[2],
               r5r_segura_min = r$segura[1], r5r_segura_exp = r$segura[2])
  })
  res <- do.call(rbind, filas)
  write.csv(res, RUTA_BENCH, row.names = FALSE)
  message("Listo: ", nrow(res), " pares en ", RUTA_BENCH)
  print(res)
}
