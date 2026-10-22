# ============================================================
# 02_simulacion_resultados.R
# Genera N pares origen-destino aleatorios dentro de CABA,
# calcula ruta directa vs. ruta óptima para cada uno, y aplica
# una prueba t de Student pareada para validar si la reducción
# de riesgo es estadísticamente significativa.
#
# Esto es lo que alimenta la sección "Resultados" del informe:
# NO se reporta un "% de acierto" (esto no es un clasificador),
# se reporta la magnitud y significancia de la reducción de
# exposición al riesgo (B) y su costo en tiempo (1-A).
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("01_preparar_riesgo.R")) "01_preparar_riesgo.R" else "R/01_preparar_riesgo.R")
source(if (file.exists("funciones_core.R")) "funciones_core.R" else "R/funciones_core.R")

N_SIMULACIONES <- 100
SEMILLA <- 123

#' Genera N puntos aleatorios (lat/lon) dentro del bbox de CABA.
#' Nota: para una versión más realista, reemplazar por muestreo
#' ponderado por densidad poblacional de barrio (shapefile INDEC).
generar_puntos_aleatorios <- function(n, bbox = CABA_BBOX, semilla = SEMILLA) {
  set.seed(semilla)
  data.frame(
    lat = runif(n, bbox["ymin"], bbox["ymax"]),
    lon = runif(n, bbox["xmin"], bbox["xmax"])
  )
}

#' Corre la simulación completa de N trayectos y arma la tabla comparativa.
correr_simulacion <- function(n = N_SIMULACIONES) {
  grilla_riesgo <- obtener_grilla_riesgo()

  origenes  <- generar_puntos_aleatorios(n, semilla = SEMILLA)
  destinos  <- generar_puntos_aleatorios(n, semilla = SEMILLA + 1)

  resultados <- vector("list", n)

  for (i in seq_len(n)) {
    origen  <- list(lat = origenes$lat[i],  lon = origenes$lon[i])
    destino <- list(lat = destinos$lat[i], lon = destinos$lon[i])

    resultado_i <- tryCatch({
      t0 <- Sys.time()

      ruta_directa <- obtener_ruta(origen, destino)
      waypoints <- proponer_waypoints_desvio(ruta_directa, grilla_riesgo, n_desvios = 2)
      rutas_candidatas <- c(
        list(ruta_directa),
        lapply(waypoints, function(wp) obtener_ruta(origen, destino, via = wp))
      )
      seleccion <- seleccionar_mejor_candidata(rutas_candidatas, grilla_riesgo)
      tabla <- seleccion$tabla
      idx_optima <- seleccion$idx_optima
      t_resp <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

      data.frame(
        trayecto = i,
        duracion_base = tabla$duracion_min[1],
        duracion_optima = tabla$duracion_min[idx_optima],
        riesgo_base = tabla$riesgo_abs[1],
        riesgo_optimo = tabla$riesgo_abs[idx_optima],
        A_eficacia = calcular_eficacia(tabla$riesgo_abs[1], tabla$riesgo_abs[idx_optima]),
        B_tiempo_respuesta = calcular_tiempo_respuesta(t_resp),
        t_respuesta_seg = t_resp
      )
    }, error = function(e) {
      message("Trayecto ", i, " omitido (", conditionMessage(e), ")")
      NULL
    })

    resultados[[i]] <- resultado_i
    incProgress <- NULL  # placeholder si se corre dentro de Shiny en modo batch
  }

  do.call(rbind, resultados)
}

#' Aplica la prueba t pareada y arma el resumen para el informe.
analizar_resultados <- function(tabla_resultados) {
  prueba_riesgo <- t.test(
    tabla_resultados$riesgo_base, tabla_resultados$riesgo_optimo,
    paired = TRUE, alternative = "greater"
  )

  incremento_tiempo_pct <- with(tabla_resultados,
    mean((duracion_optima - duracion_base) / duracion_base) * 100
  )
  reduccion_riesgo_pct <- with(tabla_resultados,
    mean((riesgo_base - riesgo_optimo) / pmax(riesgo_base, 1e-9)) * 100
  )

  list(
    n = nrow(tabla_resultados),
    prueba_t = prueba_riesgo,
    incremento_tiempo_pct_promedio = incremento_tiempo_pct,
    reduccion_riesgo_pct_promedio = reduccion_riesgo_pct
  )
}

#' Imprime un resumen en formato apto para pegar en la sección Resultados.
#' Nota: el % de reducción de riesgo y el % de incremento de tiempo son
#' RESULTADOS del problema resuelto (se reportan en Resultados). Las
#' variables A (Eficacia) y B (Tiempo de respuesta) son las variables
#' de evaluación académica definidas en Materiales y Métodos.
imprimir_resumen <- function(analisis, tabla_resultados) {
  cat(sprintf(
    "Sobre %d trayectos simulados, la ruta óptima redujo la exposición\n",
    analisis$n
  ))
  cat(sprintf(
    "al riesgo en un %.1f%% promedio respecto de la ruta más rápida\n",
    analisis$reduccion_riesgo_pct_promedio
  ))
  cat(sprintf(
    "(prueba t de Student pareada: t = %.2f, p = %.4g), a costa de un\n",
    analisis$prueba_t$statistic, analisis$prueba_t$p.value
  ))
  cat(sprintf(
    "incremento promedio del tiempo de viaje del %.1f%%.\n\n",
    analisis$incremento_tiempo_pct_promedio
  ))
  cat(sprintf(
    "Variable A (Eficacia) promedio: %.2f | Variable B (Tiempo de respuesta) promedio: %.2f\n",
    mean(tabla_resultados$A_eficacia), mean(tabla_resultados$B_tiempo_respuesta)
  ))
  cat(sprintf(
    "Tiempo de respuesta real promedio del prototipo: %.2f segundos.\n",
    mean(tabla_resultados$t_respuesta_seg)
  ))
}

#' Ejemplo de set de prueba de 50 direcciones para medir C (Robustez de
#' geocodificación). Reemplazar por direcciones reales verificadas a mano
#' (lat_real/lon_real obtenidas, por ejemplo, de Google Maps) antes del
#' informe final — estas son solo un placeholder ilustrativo.
construir_set_prueba_geocodificacion <- function() {
  data.frame(
    texto = c(
      "Av. Cnel. Díaz 1700", "Plaza de Mayo", "Av 9 de Julio y Corrientes",
      "Parque Centenario", "Av. Rivadavia 5000", "Microcentro, Florida 500"
      # completar hasta 50 direcciones reales con su lat/lon verificada
    ),
    lat_real = c(-34.5875, -34.6083, -34.6037, -34.6061, -34.6198, -34.6006),
    lon_real = c(-58.4257, -58.3712, -58.3816, -58.4349, -58.4347, -58.3754)
  )
}

# --- Ejecución directa del script -----------------------------
if (sys.nframe() == 0) {
  dir.create("data", showWarnings = FALSE)
  tabla <- correr_simulacion(N_SIMULACIONES)
  write.csv(tabla, "data/resultados_simulacion.csv", row.names = FALSE)

  analisis <- analizar_resultados(tabla)
  imprimir_resumen(analisis, tabla)

  # Variable C (Robustez de geocodificación): se mide UNA vez, aparte,
  # sobre un set de direcciones reales — no en el loop de 100 trayectos.
  valor_c <- test_robustez_geocodificacion(construir_set_prueba_geocodificacion())
  cat(sprintf("Variable C (Robustez de geocodificación): %.2f\n", valor_c))

  eficiencia_global_e <- ALPHA_TIEMPO * mean(tabla$A_eficacia) +
    BETA_RIESGO * mean(tabla$B_tiempo_respuesta) +
    GAMMA_EFICIENCIA * valor_c
  cat(sprintf("Eficiencia global E del prototipo: %.2f\n", eficiencia_global_e))

  # Gráfico comparativo riesgo base vs. óptimo (para incluir en el informe)
  library(ggplot2)
  tabla_larga <- data.frame(
    trayecto = rep(tabla$trayecto, 2),
    riesgo = c(tabla$riesgo_base, tabla$riesgo_optimo),
    ruta = rep(c("Ruta más rápida", "Ruta óptima"), each = nrow(tabla))
  )
  grafico <- ggplot(tabla_larga, aes(x = ruta, y = riesgo, fill = ruta)) +
    geom_boxplot() +
    labs(title = "Exposición al riesgo: ruta más rápida vs. ruta óptima",
         x = NULL, y = "Exposición acumulada (riesgo)") +
    theme_minimal() +
    theme(legend.position = "none")
  ggsave("data/comparacion_riesgo.png", grafico, width = 6, height = 4, dpi = 150)
}
