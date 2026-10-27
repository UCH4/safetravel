# ============================================================
# 07_grilla_produccion.R
# Grilla de riesgo para la app con todo el histórico disponible
# (robos y hurtos 2016-2025, sin 2020-2021), con los parámetros
# ajustados en R/01_preparar_riesgo.R (tamaño de celda y peso nocturno).
#
# La validación (entrenamiento 2016-2019 y 2022-2023, prueba 2025) sigue
# en data/grilla_riesgo_validacion_2016_2023.rds, con su Spearman.
#
# Salida: data/grilla_riesgo.rds (la que usa la app y el ETL de transporte)
# Ejecutar con: Rscript R/07_grilla_produccion.R
# ============================================================

source(if (file.exists("01_preparar_riesgo.R")) "01_preparar_riesgo.R" else "R/01_preparar_riesgo.R")

ruta_validacion <- file.path(RUTA_DATOS, "grilla_riesgo_validacion_2016_2023.rds")
ruta_salida <- file.path(RUTA_DATOS, "grilla_riesgo.rds")

validacion <- readRDS(ruta_validacion)
parametros_val <- attr(validacion, "parametros")

datos <- cargar_delitos_caba(2016:2025)
area <- cargar_area_ciudad()
eventos <- filtrar_delitos_riesgo(datos, area$geo)
eventos_proy <- sf::st_transform(eventos, CRS_PROYECTADO)
pesos <- peso_franja(eventos_proy$franja, parametros_val$peso_nocturno)
grilla <- construir_grilla_desde_eventos(eventos_proy, area$proy, parametros_val$tamano_celda, pesos)

attr(grilla, "parametros") <- list(
  tamano_celda = parametros_val$tamano_celda,
  peso_nocturno = parametros_val$peso_nocturno,
  anios = sort(setdiff(2016:2025, ANIOS_EXCLUIDOS)),
  spearman_prueba_2025 = parametros_val$spearman_prueba_2025,
  fuente = "CABA - Delitos (robos y hurtos), 2016-2025 excepto 2020-2021"
)
saveRDS(grilla, ruta_salida)
message("Grilla de producción: ", nrow(grilla), " celdas, ", nrow(eventos_proy),
        " delitos. Guardada en ", ruta_salida)
