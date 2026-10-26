# ============================================================
# 04_evaluacion_transporte.R
# Evaluación propia del ruteo sesgado por riesgo en colectivos.
#
#   a) Verificación de la base data/transporte.sqlite (integridad,
#      cobertura de riesgo, plausibilidad de tiempos y esperas).
#   b) Comparación en 50 pares de puntos dentro de CABA:
#      ruta más rápida (factor_sesgo = 0) vs. ruta sesgada (factor_sesgo = 1).
#      Métricas: exposición al riesgo, tiempo de viaje, transbordos.
#      Prueba de Wilcoxon pareada sobre la exposición.
#
# Salidas: data/evaluacion_transporte.csv (un renglón por par)
#          data/evaluacion_transporte_resumen.txt
#
# Ejecutar con: Rscript R/04_evaluacion_transporte.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("transporte.R")) "transporte.R" else "R/transporte.R")

RUTA_EVALUACION <- file.path(RUTA_DATOS, "evaluacion_transporte.csv")
RUTA_RESUMEN <- file.path(RUTA_DATOS, "evaluacion_transporte_resumen.txt")
N_PARES <- 50
FRANJA_EVAL <- "Tarde"
SEMILLA <- 2026

#' a) Verificación de la base de topología. Devuelve un vector de textos con los resultados.
verificar_base <- function(ruta_db = RUTA_DB_TRANSPORTE) {
  con <- DBI::dbConnect(RSQLite::SQLite(), ruta_db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  q <- function(s) DBI::dbGetQuery(con, s)
  tablas <- DBI::dbListTables(con)
  integridad <- q("SELECT
      (SELECT COUNT(*) FROM conectividad c LEFT JOIN paradas_riesgo p ON p.id_parada = c.id_parada_origen WHERE p.id_parada IS NULL) AS huerfanos_origen,
      (SELECT COUNT(*) FROM conectividad c LEFT JOIN paradas_riesgo p ON p.id_parada = c.id_parada_destino WHERE p.id_parada IS NULL) AS huerfanos_destino,
      (SELECT COUNT(*) FROM conectividad c LEFT JOIN lineas_recorridos l ON l.id_ruta = c.id_ruta WHERE l.id_ruta IS NULL) AS rutas_sin_linea")
  riesgo <- q("SELECT COUNT(*) AS paradas, SUM(score_riesgo IS NULL) AS sin_dato,
                      SUM(score_riesgo > 0) AS con_riesgo, ROUND(AVG(score_riesgo), 4) AS media
               FROM paradas_riesgo")
  tiempos <- q("SELECT ROUND(MIN(tiempo_estimado_entre_paradas), 2) AS min_min,
                       ROUND(AVG(tiempo_estimado_entre_paradas), 2) AS prom_min,
                       ROUND(MAX(tiempo_estimado_entre_paradas), 2) AS max_min,
                       SUM(tiempo_estimado_entre_paradas > 30) AS tramos_mayores_30_min
                FROM conectividad")
  c(
    sprintf("Tablas: %s", paste(tablas, collapse = ", ")),
    sprintf("Huérfanos (debe ser 0): origen %d, destino %d, rutas sin línea %d",
            integridad$huerfanos_origen, integridad$huerfanos_destino, integridad$rutas_sin_linea),
    sprintf("Paradas: %d. Con score de riesgo (dentro de CABA): %d. Sin dato (fuera de la grilla): %d. Score medio: %.4f",
            riesgo$paradas, riesgo$con_riesgo, riesgo$sin_dato, riesgo$media),
    sprintf("Tiempo por tramo (min): mínimo %.2f, promedio %.2f, máximo %.2f. Tramos > 30 min: %d",
            tiempos$min_min, tiempos$prom_min, tiempos$max_min, tiempos$tramos_mayores_30_min)
  )
}

#' b) Pares de evaluación: centroides de celdas de la grilla, separados entre 2 y 8 km.
generar_pares <- function(n = N_PARES, semilla = SEMILLA) {
  grilla <- readRDS(file.path(RUTA_DATOS, "grilla_riesgo.rds"))
  c_ll <- sf::st_coordinates(sf::st_transform(sf::st_centroid(grilla), CRS_GEOGRAFICO))
  set.seed(semilla)
  pares <- list()
  while (length(pares) < n) {
    i <- sample(nrow(c_ll), 1); j <- sample(nrow(c_ll), 1)
    d <- distancias_m(c_ll[i, 2], c_ll[i, 1], c_ll[j, 2], c_ll[j, 1])
    if (d >= 2000 && d <= 8000) {
      pares[[length(pares) + 1]] <- list(
        origen = list(lat = c_ll[i, 2], lon = c_ll[i, 1]),
        destino = list(lat = c_ll[j, 2], lon = c_ll[j, 1]),
        distancia_m = d
      )
    }
  }
  pares
}

#' Ruta única más rápida o sesgada (k = 1). NULL si no hay recorrido.
#' El motivo del fallo se avisa en consola (no se oculta).
ruta_unica <- function(par, factor) {
  tryCatch(
    calcular_colectivo_seguro(par$origen, par$destino, franja = FRANJA_EVAL,
                              factor_sesgo = factor, k_alternativas = 1)[[1]],
    error = function(e) {
      message("  sin recorrido (factor ", factor, "): ", conditionMessage(e))
      NULL
    }
  )
}

#' Compara ruta rápida vs. sesgada hasta obtener N_PARES pares con recorrido.
#' Si un par no tiene recorrido, se reemplaza por el siguiente generado (no se descarta sin más).
comparar_rutas <- function(pares_candidatos, n_objetivo = N_PARES) {
  filas <- list(); usados <- 0
  for (p in pares_candidatos) {
    if (length(filas) >= n_objetivo) break
    usados <- usados + 1
    rapida <- ruta_unica(p, 0)
    segura <- ruta_unica(p, 1)
    if (is.null(rapida) || is.null(segura)) next
    filas[[length(filas) + 1]] <- data.frame(
      par = usados, distancia_m = round(p$distancia_m),
      tiempo_rapida_min = rapida$duracion_min, tiempo_segura_min = segura$duracion_min,
      exposicion_rapida = rapida$exposicion, exposicion_segura = segura$exposicion,
      riesgo_medio_rapida = rapida$riesgo_medio, riesgo_medio_segura = segura$riesgo_medio,
      transbordos_rapida = rapida$transbordos, transbordos_segura = segura$transbordos
    )
  }
  if (length(filas) < n_objetivo) {
    warning("Solo ", length(filas), " de ", n_objetivo, " pares tuvieron recorrido.")
  }
  res <- do.call(rbind, filas)
  # Protección contra división por cero: exposición 0 en la ruta rápida no tiene reducción relativa
  base_expo <- ifelse(res$exposicion_rapida > 0, res$exposicion_rapida, NA_real_)
  res$reduccion_exposicion_pct <- 100 * (res$exposicion_rapida - res$exposicion_segura) / base_expo
  res$aumento_tiempo_pct <- 100 * (res$tiempo_segura_min - res$tiempo_rapida_min) / res$tiempo_rapida_min
  res
}

#' Resumen en texto para pegar en el informe.
resumir_evaluacion <- function(res, verificacion, n_pares) {
  w <- suppressWarnings(wilcox.test(res$exposicion_segura, res$exposicion_rapida,
                                    paired = TRUE, alternative = "less"))
  c(
    "VERIFICACIÓN DE LA BASE",
    verificacion,
    "",
    sprintf("COMPARACIÓN EN %d PARES DE PUNTOS DENTRO DE CABA (franja %s, distancia 2-8 km)", nrow(res), FRANJA_EVAL),
    sprintf("Pares evaluados: %d de %d (los demás no tuvieron recorrido)", nrow(res), n_pares),
    sprintf("Exposición: mediana de reducción %.1f %% (IQR %.1f a %.1f %%)",
            median(res$reduccion_exposicion_pct), quantile(res$reduccion_exposicion_pct, .25),
            quantile(res$reduccion_exposicion_pct, .75)),
    sprintf("Tiempo: mediana de aumento %.1f %% (IQR %.1f a %.1f %%)",
            median(res$aumento_tiempo_pct), quantile(res$aumento_tiempo_pct, .25),
            quantile(res$aumento_tiempo_pct, .75)),
    sprintf("Pares con reducción de exposición >= 10 %%: %d de %d",
            sum(res$reduccion_exposicion_pct >= 10), nrow(res)),
    sprintf("Pares con mismo recorrido (sin cambio): %d de %d",
            sum(abs(res$reduccion_exposicion_pct) < 1e-6), nrow(res)),
    sprintf("Wilcoxon pareado (exposición segura < rápida): V = %s, p = %.4g",
            w$statistic, w$p.value),
    sprintf("Transbordos medios: rápida %.2f, segura %.2f",
            mean(res$transbordos_rapida), mean(res$transbordos_segura)),
    "",
    "Nota: el sesgo solo actúa donde hay score de riesgo (dentro de CABA). Ver OBJETIVOS.md."
  )
}

if (sys.nframe() == 0) {
  verificacion <- verificar_base()
  message("Generando ", N_PARES, " pares y comparando rutas...")
  pares <- generar_pares(n = 2 * N_PARES)   # candidatos de reserva para reemplazar pares sin recorrido
  res <- comparar_rutas(pares)
  write.csv(res, RUTA_EVALUACION, row.names = FALSE)
  resumen <- resumir_evaluacion(res, verificacion, N_PARES)
  writeLines(resumen, RUTA_RESUMEN)
  cat(resumen, sep = "\n")
}
