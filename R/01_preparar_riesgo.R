# ============================================================
# 01_preparar_riesgo.R
# Construye la grilla de riesgo delictivo a partir de los datos
# oficiales de CABA (2016-2025), siguiendo la sección 2 de la
# Introducción del TP:
#   - robos y hurtos (sin 2020-2021, pandemia)
#   - coordenadas validadas y asignación a barrios (GeoJSON)
#   - grilla de celdas cuadradas en EPSG:5347 (POSGAR 2007 / UTM 21S)
#   - ponderación horaria (franja nocturna)
#   - partición cronológica: entrenamiento / ajuste 2024 / prueba 2025
#
# Si los datos reales no están en data/raw/, recurre a una grilla
# SINTÉTICA de demostración (ver obtener_grilla_riesgo()).
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")

# --- Rutas de datos (ver data/raw/ y README) ------------------
RUTA_RAW           <- file.path(RUTA_DATOS, "raw")
RUTA_GEOJSON_BARRIOS <- file.path(RUTA_RAW, "barrios.geojson")
ARCHIVO_DELITOS    <- function(anio) file.path(RUTA_RAW, sprintf("delitos_%d.csv", anio))

#' Lee y une los CSV anuales de delitos de CABA.
#' @return data.frame con columnas originales más lat, lon (numéricas) y anio (entero)
cargar_delitos_caba <- function(anios = 2016:2025) {
  archivos <- vapply(anios, ARCHIVO_DELITOS, character(1))
  faltan <- archivos[!file.exists(archivos)]
  if (length(faltan) > 0) {
    stop("Faltan archivos de delitos: ", paste(basename(faltan), collapse = ", "))
  }

  datos <- lapply(archivos, function(f) {
    read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
  })
  d <- do.call(rbind, datos)

  d$anio  <- as.integer(d$anio)
  d$franja <- suppressWarnings(as.integer(d$franja))
  # "NULL" y valores vacíos quedan como NA; los números corruptos se filtran después
  d$lat <- suppressWarnings(as.numeric(d$latitud))
  d$lon <- suppressWarnings(as.numeric(d$longitud))
  d
}

#' Filtra los registros válidos para la grilla de riesgo.
#' 1) tipos de delito del documento, 2) sin 2020-2021,
#' 3) coordenadas numéricas dentro del bounding box de CABA,
#' 4) dentro de la geometría unificada de los barrios.
#' @param area_geo polígono unificado de los barrios (EPSG:4326)
filtrar_delitos_riesgo <- function(datos, area_geo,
                                   tipos = TIPOS_DELITO_RIESGO,
                                   anios_excluidos = ANIOS_EXCLUIDOS) {
  d <- datos[datos$tipo %in% tipos & !(datos$anio %in% anios_excluidos), ]

  dentro_bbox <- !is.na(d$lat) & !is.na(d$lon) &
    d$lon >= CABA_BBOX["xmin"] & d$lon <= CABA_BBOX["xmax"] &
    d$lat >= CABA_BBOX["ymin"] & d$lat <= CABA_BBOX["ymax"]
  d <- d[dentro_bbox, ]

  puntos <- sf::st_as_sf(d, coords = c("lon", "lat"), crs = CRS_GEOGRAFICO, remove = FALSE)
  en_barrios <- lengths(sf::st_intersects(puntos, area_geo)) > 0
  puntos[en_barrios, ]
}

#' Peso horario: los eventos nocturnos pesan `peso_nocturno`, el resto 1.
#' Los registros sin franja (NA) pesan 1.
peso_franja <- function(franja, peso_nocturno) {
  ifelse(!is.na(franja) & franja %in% FRANJAS_NOCTURNAS, peso_nocturno, 1)
}

#' Índice de celda (fila/columna) de cada punto en una grilla regular
#' que empieza en (xmin, ymin).
indice_celda <- function(x, y, xmin, ymin, tamano_celda) {
  data.frame(
    ix = floor((x - xmin) / tamano_celda) + 1,
    iy = floor((y - ymin) / tamano_celda) + 1
  )
}

#' Suma los pesos de los eventos por celda.
#' @return vector con nombre "ix_iy" -> suma de pesos
sumar_por_celda <- function(puntos_proy, xmin, ymin, tamano_celda, pesos = NULL) {
  coords <- sf::st_coordinates(puntos_proy)
  idx <- indice_celda(coords[, 1], coords[, 2], xmin, ymin, tamano_celda)
  if (is.null(pesos)) pesos <- rep(1, nrow(idx))
  clave <- paste(idx$ix, idx$iy, sep = "_")
  tapply(pesos, clave, sum)
}

#' Construye la grilla de riesgo para un conjunto de eventos.
#' @param puntos_proy eventos ya filtrados, en EPSG:5347
#' @param area_proy polígono unificado de barrios, en EPSG:5347
#' @param pesos peso por evento (ponderación horaria)
#' @return objeto sf con id_celda, conteo, conteo_ponderado, riesgo (0-1)
construir_grilla_desde_eventos <- function(puntos_proy, area_proy,
                                           tamano_celda = TAMANO_CELDA_M,
                                           pesos = NULL) {
  grilla <- sf::st_make_grid(area_proy, cellsize = tamano_celda, square = TRUE)
  grilla_sf <- sf::st_sf(id_celda = seq_along(grilla), geometry = grilla)

  # Solo celdas que tocan la Ciudad
  grilla_sf <- grilla_sf[lengths(sf::st_intersects(grilla_sf, area_proy)) > 0, ]

  xmin <- sf::st_bbox(area_proy)["xmin"]
  ymin <- sf::st_bbox(area_proy)["ymin"]
  centroides <- sf::st_coordinates(sf::st_centroid(grilla_sf))
  idx_celdas <- indice_celda(centroides[, 1], centroides[, 2], xmin, ymin, tamano_celda)
  clave_celdas <- paste(idx_celdas$ix, idx_celdas$iy, sep = "_")

  conteo <- sumar_por_celda(puntos_proy, xmin, ymin, tamano_celda, pesos = NULL)
  conteo_pond <- sumar_por_celda(puntos_proy, xmin, ymin, tamano_celda, pesos = pesos)

  grilla_sf$conteo <- as.numeric(ifelse(is.na(conteo[clave_celdas]), 0, conteo[clave_celdas]))
  grilla_sf$conteo_ponderado <- as.numeric(ifelse(is.na(conteo_pond[clave_celdas]), 0,
                                                 conteo_pond[clave_celdas]))

  # Normalización lineal 0-1 respecto de la celda de mayor densidad (sección 2)
  maximo <- max(grilla_sf$conteo_ponderado)
  grilla_sf$riesgo <- if (maximo > 0) grilla_sf$conteo_ponderado / maximo else 0
  grilla_sf
}

#' Carga la geometría de la Ciudad (unión de barrios) en EPSG:4326 y EPSG:5347.
cargar_area_ciudad <- function(ruta = RUTA_GEOJSON_BARRIOS) {
  barrios <- sf::st_read(ruta, quiet = TRUE)
  # 5 de los 48 barrios vienen con geometría inválida (anillos degenerados)
  geometrias <- sf::st_make_valid(sf::st_geometry(barrios))
  area_geo <- sf::st_union(geometrias)
  list(
    geo  = sf::st_sf(geometry = area_geo, crs = CRS_GEOGRAFICO),
    proy = sf::st_transform(sf::st_sf(geometry = area_geo, crs = CRS_GEOGRAFICO), CRS_PROYECTADO)
  )
}

#' Spearman entre riesgo predicho (entrenamiento) y conteos reales de un año.
#' Es invariante a la normalización lineal, por eso se evalúa sobre el riesgo crudo.
correlacion_celdas <- function(grilla_riesgo, puntos_objetivo_proy, xmin, ymin, tamano_celda) {
  conteo_obj <- sumar_por_celda(puntos_objetivo_proy, xmin, ymin, tamano_celda)
  coords <- sf::st_coordinates(sf::st_centroid(grilla_riesgo))
  idx <- indice_celda(coords[, 1], coords[, 2], xmin, ymin, tamano_celda)
  clave <- paste(idx$ix, idx$iy, sep = "_")
  real <- as.numeric(ifelse(is.na(conteo_obj[clave]), 0, conteo_obj[clave]))
  suppressWarnings(stats::cor(grilla_riesgo$conteo_ponderado, real, method = "spearman"))
}

#' Ajuste sobre el año de ajuste (2024): elige tamaño de celda y peso nocturno.
#' La prueba 2025 NO se usa aquí.
ajustar_parametros_grilla <- function(datos, area) {
  ajuste_eventos <- filtrar_delitos_riesgo(datos[datos$anio %in% c(ANIOS_ENTRENAMIENTO, ANIO_AJUSTE), ], area$geo)
  ajuste_eventos_proy <- sf::st_transform(ajuste_eventos, CRS_PROYECTADO)
  entrenamiento <- ajuste_eventos_proy[ajuste_eventos_proy$anio %in% ANIOS_ENTRENAMIENTO, ]
  ajuste <- ajuste_eventos_proy[ajuste_eventos_proy$anio == ANIO_AJUSTE, ]

  resultados <- expand.grid(tamano = TAMANOS_CELDA_CANDIDATOS,
                            peso_noct = PESO_NOCTURNO_CANDIDATOS)
  resultados$spearman_2024 <- NA_real_

  for (k in seq_len(nrow(resultados))) {
    tam <- resultados$tamano[k]
    pesos <- peso_franja(entrenamiento$franja, resultados$peso_noct[k])
    grilla <- construir_grilla_desde_eventos(entrenamiento, area$proy, tam, pesos)
    xmin <- sf::st_bbox(area$proy)["xmin"]; ymin <- sf::st_bbox(area$proy)["ymin"]
    resultados$spearman_2024[k] <- correlacion_celdas(grilla, ajuste, xmin, ymin, tam)
  }

  mejor <- resultados[which.max(resultados$spearman_2024), ]
  list(tabla = resultados, tamano = mejor$tamano, peso_noct = mejor$peso_noct)
}

#' Construye la grilla final con los parámetros ajustados (entrenamiento 2016-2019, 2022-2023)
#' y mide su poder predictivo sobre 2025 (conjunto de prueba, una sola vez).
construir_grilla_riesgo_real <- function(datos = NULL) {
  if (is.null(datos)) datos <- cargar_delitos_caba()
  area <- cargar_area_ciudad()

  ajuste <- ajustar_parametros_grilla(datos, area)
  message(sprintf("Ajuste (2024): tamaño de celda = %d m, peso nocturno = %.1f",
                  ajuste$tamano, ajuste$peso_noct))

  eventos <- filtrar_delitos_riesgo(datos[datos$anio %in% c(ANIOS_ENTRENAMIENTO, ANIO_PRUEBA), ], area$geo)
  eventos_proy <- sf::st_transform(eventos, CRS_PROYECTADO)
  entrenamiento <- eventos_proy[eventos_proy$anio %in% ANIOS_ENTRENAMIENTO, ]
  prueba <- eventos_proy[eventos_proy$anio == ANIO_PRUEBA, ]

  pesos <- peso_franja(entrenamiento$franja, ajuste$peso_noct)
  grilla <- construir_grilla_desde_eventos(entrenamiento, area$proy, ajuste$tamano, pesos)

  xmin <- sf::st_bbox(area$proy)["xmin"]; ymin <- sf::st_bbox(area$proy)["ymin"]
  rho_prueba <- correlacion_celdas(grilla, prueba, xmin, ymin, ajuste$tamano)

  attr(grilla, "parametros") <- list(
    tamano_celda = ajuste$tamano,
    peso_nocturno = ajuste$peso_noct,
    spearman_ajuste_2024 = ajuste$tabla,
    spearman_prueba_2025 = rho_prueba,
    fuente = "CABA - Delitos (robos y hurtos), 2016-2019 y 2022-2023"
  )
  message(sprintf("Prueba 2025 (Spearman celdas, riesgo vs conteo real): %.3f", rho_prueba))
  grilla
}

#' Genera una grilla de riesgo SINTÉTICA para modo demostración/offline.
#' Simula 3-4 focos de mayor densidad delictiva dentro del bbox de CABA,
#' únicamente para que el prototipo sea ejecutable sin datos reales.
construir_grilla_riesgo_sintetica <- function(tamano_celda = TAMANO_CELDA_M, semilla = 42) {
  set.seed(semilla)

  bbox_sf <- sf::st_as_sfc(sf::st_bbox(CABA_BBOX, crs = CRS_GEOGRAFICO))
  bbox_proy <- sf::st_transform(bbox_sf, crs = CRS_PROYECTADO)

  grilla <- sf::st_make_grid(bbox_proy, cellsize = tamano_celda, square = TRUE)
  grilla_sf <- sf::st_sf(id_celda = seq_along(grilla), geometry = grilla)
  centroides <- sf::st_coordinates(sf::st_centroid(grilla_sf))

  # Focos sintéticos de "riesgo" (coordenadas proyectadas arbitrarias dentro del bbox)
  bbox_coords <- sf::st_bbox(bbox_proy)
  focos <- data.frame(
    x = runif(4, bbox_coords["xmin"], bbox_coords["xmax"]),
    y = runif(4, bbox_coords["ymin"], bbox_coords["ymax"]),
    intensidad = c(1.0, 0.8, 0.6, 0.5)
  )

  riesgo_bruto <- vapply(seq_len(nrow(grilla_sf)), function(i) {
    cx <- centroides[i, 1]; cy <- centroides[i, 2]
    d2 <- (focos$x - cx)^2 + (focos$y - cy)^2
    sum(focos$intensidad * exp(-d2 / (2 * 800^2)))
  }, numeric(1))

  maximo <- max(riesgo_bruto)
  grilla_sf$riesgo <- if (maximo > 0) riesgo_bruto / maximo else 0
  grilla_sf$conteo <- NA_integer_  # no aplica en modo sintético
  grilla_sf$conteo_ponderado <- NA_real_

  grilla_sf
}

#' Punto de entrada: intenta cargar datos reales; si no están
#' disponibles, recurre a la grilla sintética e imprime un aviso.
obtener_grilla_riesgo <- function() {
  tryCatch({
    grilla <- construir_grilla_riesgo_real()
    message("Grilla de riesgo construida a partir de datos reales (CABA Data).")
    grilla
  }, error = function(e) {
    message("[AVISO] Datos reales no disponibles (", conditionMessage(e),
            "). Usando grilla SINTÉTICA de demostración.")
    construir_grilla_riesgo_sintetica()
  })
}

# Al correr este script de forma independiente, genera y guarda la grilla:
if (sys.nframe() == 0) {
  grilla_riesgo <- obtener_grilla_riesgo()
  dir.create(RUTA_DATOS, showWarnings = FALSE)
  saveRDS(grilla_riesgo, file.path(RUTA_DATOS, "grilla_riesgo.rds"))
  message("Grilla guardada en ", file.path(RUTA_DATOS, "grilla_riesgo.rds"),
          " (", nrow(grilla_riesgo), " celdas).")
}
