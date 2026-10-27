# ============================================================
# 06_trazados_colectivos.R
# Trazados reales de las líneas de colectivo (RMBA) para dibujarlas
# por la calle y no como líneas rectas entre paradas.
#
# Fuente: "Recorridos de Líneas de Transporte de RMBA" (datos.transporte.gob.ar),
# archivos GeoJSON de jurisdicción nacional, provincial y municipal, en data/raw/.
# Cada feature es un trazado (LINEA, RAMAL, SENTIDO). Se guarda una lista por número
# de línea con las coordenadas simplificadas (tolerancia ~5 m).
#
# Salida: data/trazados_colectivos.rds
#   list(<linea> = list(list(ramal, sentido, lat, lon), ...))
#
# Ejecutar con: Rscript R/06_trazados_colectivos.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")

suppressPackageStartupMessages(library(sf))

RUTA_TRAZADOS <- file.path(RUTA_DATOS, "trazados_colectivos.rds")
TOLERANCIA_SIMPLIFICAR <- 0.00005   # grados (~5 m)

#' Lee los tres GeoJSON de RMBA y devuelve un sf en EPSG:4326 con LINEA, RAMAL y SENTIDO.
leer_trazados_rmba <- function(carpeta = file.path(RUTA_DATOS, "raw")) {
  archivos <- file.path(carpeta, sprintf("rmba_bus_%s.geojson", c("nacional", "provincial", "municipal")))
  faltan <- archivos[!file.exists(archivos)]
  if (length(faltan) > 0) stop("Faltan: ", paste(faltan, collapse = ", "))
  capas <- lapply(archivos, function(f) {
    s <- st_read(f, quiet = TRUE)
    s <- st_zm(s)
    st_transform(s[, c("LINEA", "RAMAL", "SENTIDO")], 4326)
  })
  do.call(rbind, capas)
}

#' Agrupa los trazados por número de línea. Cada parte de una geometría multiparte queda
#' como trazado aparte (así no se unen partes separadas con líneas largas). Solo las partes
#' con al menos dos puntos. Coordenadas en orden de recorrido.
construir_trazados <- function(trazados) {
  partes <- lapply(seq_len(nrow(trazados)), function(i) {
    m <- st_coordinates(st_simplify(trazados$geometry[i], dTolerance = TOLERANCIA_SIMPLIFICAR))
    grupo <- if ("L1" %in% colnames(m)) m[, "L1"] else rep(1, nrow(m))
    lapply(split(seq_len(nrow(m)), grupo), function(k) {
      list(linea = as.character(trazados$LINEA[i]), ramal = as.character(trazados$RAMAL[i]),
           sentido = as.character(trazados$SENTIDO[i]), lat = m[k, "Y"], lon = m[k, "X"])
    })
  })
  partes <- Filter(function(t) length(t$lat) >= 2, unlist(partes, recursive = FALSE))
  linea <- vapply(partes, function(t) t$linea, character(1))
  lapply(split(partes, linea), function(ps) lapply(ps, function(t) t[c("ramal", "sentido", "lat", "lon")]))
}

if (sys.nframe() == 0) {
  message("Leyendo trazados RMBA...")
  trazados <- leer_trazados_rmba()
  lista <- construir_trazados(trazados)
  saveRDS(lista, RUTA_TRAZADOS)
  message("Listo: ", length(lista), " líneas, ", length(unlist(lista, recursive = FALSE)),
          " trazados. Guardado en ", RUTA_TRAZADOS,
          " (", round(file.size(RUTA_TRAZADOS) / 1e6, 1), " MB).")
}
