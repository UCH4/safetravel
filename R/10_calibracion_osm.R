# ============================================================
# 10_calibracion_osm.R
# Calibra la base OSM (09_base_osm.R) contra r5r en los mismos 10 pares de 08.
#
# Parámetros que se varían (no se tocan los archivos de origen):
#   - velocidad de bus (km/h): la base guarda tiempos a 15 km/h; se reescalan.
#   - penalización por subida (min): PENALIZACION_SUBIDA_MIN de transporte.R.
#   - escala de la espera: multiplica las esperas de la base (intervalos 2019).
#
# Métrica: tiempo de la opción más rápida de cada método. Se compara con r5r
# (pares donde r5r tiene ruta) por error absoluto mediano, correlación de
# Spearman y cobertura (pares con ruta).
#
# Salida: data/calibracion_osm.csv (una fila por variante)
# Ejecutar con: Rscript R/10_calibracion_osm.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("transporte.R")) "transporte.R" else "R/transporte.R")
source(if (file.exists("08_benchmark_r5r.R")) "08_benchmark_r5r.R" else "R/08_benchmark_r5r.R")

RUTA_DB_OSM <- file.path(RUTA_DATOS, "transporte_osm.sqlite")
RUTA_CALIBRACION <- file.path(RUTA_DATOS, "calibracion_osm.csv")
RUTA_CALIBRACION_PARES <- file.path(RUTA_DATOS, "calibracion_osm_pares.csv")
VELOCIDAD_BASE_OSM_KMH <- 20  # velocidad con la que se generó data/transporte_osm.sqlite (09_base_osm.R)
GRID_VELOCIDAD <- c(15, 20, 25)
GRID_PENALIZACION <- c(1, 3)
GRID_ESPERA <- c(1, 0.5)

#' Carga la base OSM con una velocidad, penalización y escala de espera dadas.
#' Reinicia el caché de transporte para que el grafo se rearme con esos valores.
preparar_variante <- function(velocidad_kmh, penalizacion_min, escala_espera) {
  PENALIZACION_SUBIDA_MIN <<- penalizacion_min
  RUTA_DB_TRANSPORTE <<- RUTA_DB_OSM
  rm(list = ls(.cache_transporte), envir = .cache_transporte)
  topo <- cargar_topologia(RUTA_DB_OSM)
  con <- data.table::copy(topo$conectividad)
  con[, tiempo_estimado_entre_paradas := tiempo_estimado_entre_paradas * VELOCIDAD_BASE_OSM_KMH / velocidad_kmh]
  con[, espera_manana_min := espera_manana_min * escala_espera]
  con[, espera_tarde_min := espera_tarde_min * escala_espera]
  con[, espera_noche_min := espera_noche_min * escala_espera]
  topo$conectividad <- con
  .cache_transporte$topo <- topo
  invisible(TRUE)
}

#' Tiempo (min) de la opción más rápida con la variante activa, o NA si no hay ruta.
rapida_variante <- function(par) {
  r <- tryCatch(calcular_colectivo_seguro(par$origen, par$destino, franja = "Tarde",
                                          factor_sesgo = 0, k_alternativas = 1)[[1]],
                error = function(e) NULL)
  if (is.null(r)) NA_real_ else r$duracion_min
}

if (sys.nframe() == 0) {
  options(java.parameters = "-Xmx12G")
  pares <- pares_benchmark()
  bench_r5r <- read.csv(file.path(RUTA_DATOS, "benchmark_r5r.csv"))
  r5r_min <- bench_r5r$r5r_rapida_min

  google_min <- read.csv(file.path(RUTA_DATOS, "google_maps_pares.csv"))$google_transporte_min

  variantes <- expand.grid(velocidad = GRID_VELOCIDAD, penalizacion = GRID_PENALIZACION,
                           espera = GRID_ESPERA)
  resultados <- lapply(seq_len(nrow(variantes)), function(v) {
    cfg <- variantes[v, ]
    message("Variante ", v, " de ", nrow(variantes), ": ", cfg$velocidad, " km/h, subida ",
            cfg$penalizacion, " min, espera x", cfg$espera)
    preparar_variante(cfg$velocidad, cfg$penalizacion, cfg$espera)
    list(cfg = cfg, propio = vapply(pares, rapida_variante, 0))
  })

  metricas <- function(propio, ref) {
    ok <- !is.na(propio) & !is.na(ref)
    c(pares_comunes = sum(ok),
      error_abs_mediano_min = median(abs(propio[ok] - ref[ok])),
      spearman = suppressWarnings(cor(propio[ok], ref[ok], method = "spearman")))
  }
  filas <- lapply(resultados, function(r) {
    m_r5r <- metricas(r$propio, r5r_min)
    m_g <- metricas(r$propio, google_min)
    data.frame(velocidad_kmh = r$cfg$velocidad, penalizacion_min = r$cfg$penalizacion,
               escala_espera = r$cfg$espera, pares_con_ruta = sum(!is.na(r$propio)),
               mediana_osm_min = median(r$propio, na.rm = TRUE),
               r5r_pares = m_r5r[["pares_comunes"]], r5r_error_abs_min = m_r5r[["error_abs_mediano_min"]],
               r5r_spearman = m_r5r[["spearman"]],
               google_pares = m_g[["pares_comunes"]], google_error_abs_min = m_g[["error_abs_mediano_min"]],
               google_spearman = m_g[["spearman"]])
  })
  res <- do.call(rbind, filas)
  res <- res[order(res$google_error_abs_min), ]
  write.csv(res, RUTA_CALIBRACION, row.names = FALSE)

  por_par <- data.frame(par = seq_along(pares), distancia_m = round(vapply(pares, `[[`, 0, "distancia_m")),
                        r5r_min = r5r_min, google_min = google_min)
  for (r in resultados) {
    por_par[[sprintf("osm_v%d_p%d_e%s", r$cfg$velocidad, r$cfg$penalizacion, r$cfg$espera)]] <- round(r$propio, 1)
  }
  write.csv(por_par, RUTA_CALIBRACION_PARES, row.names = FALSE)
  message("Listo: ", nrow(res), " variantes en ", RUTA_CALIBRACION)
  print(res, row.names = FALSE)
}
