# ============================================================
# 05_prueba_parque_patricios.R
# Prueba de cobertura del ruteo en colectivos alrededor de
# Parque Patricios (y hacia otros barrios de CABA).
#
# Criterio de entrega: 100 % de los pares de direcciones deben
# obtener al menos un recorrido. Cada fallo se reporta con su causa.
#
# Ejecutar con: Rscript R/05_prueba_parque_patricios.R
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
source(if (file.exists("geocodificacion.R")) "geocodificacion.R" else "R/geocodificacion.R")
source(if (file.exists("transporte.R")) "transporte.R" else "R/transporte.R")

RUTA_PRUEBA <- file.path(RUTA_DATOS, "prueba_parque_patricios.csv")

# Direcciones reales del barrio y de su entorno (Parque Patricios, Barracas, San Telmo, Constitución, La Boca)
DIRECCIONES_PRUEBA <- c(
  "Av. Caseros 2800", "Av. Caseros 3300", "Av. Caseros 1500",
  "Av. Sáenz 1000", "Av. Sáenz 2000",
  "Monteagudo 800", "Cachimayo 1200", "Iriarte 2400", "Pasco 1200",
  "Av. Vélez Sarsfield 1100", "Av. Jujuy 1000", "Hipólito Yrigoyen 3000",
  "Av. Garay 1500", "Av. Caseros y Av. Sáenz", "Av. Caseros y Monteagudo",
  "Av. Entre Ríos 800", "Av. Independencia 1500", "Av. Juan de Garay 900",
  "Av. Almirante Brown 1300", "Av. Patricios 1700"
)

#' Geocodifica las direcciones de prueba. Devuelve data.frame con texto, lat, lon, fuente.
geocodificar_prueba <- function(direcciones = DIRECCIONES_PRUEBA) {
  filas <- lapply(direcciones, function(d) {
    g <- tryCatch(geocodificar_direccion(d), error = function(e) NULL)
    if (is.null(g)) return(data.frame(texto = d, lat = NA_real_, lon = NA_real_, fuente = "sin dato"))
    data.frame(texto = d, lat = g$lat, lon = g$lon, fuente = g$fuente)
  })
  do.call(rbind, filas)
}

#' Prueba todos los pares (ida y vuelta no se repite). Devuelve un data.frame con el resultado de cada par.
probar_pares <- function(puntos, franja = franja_actual(), factor_sesgo = 1) {
  pares <- t(combn(seq_len(nrow(puntos)), 2))
  filas <- lapply(seq_len(nrow(pares)), function(k) {
    i <- pares[k, 1]; j <- pares[k, 2]
    o <- list(lat = puntos$lat[i], lon = puntos$lon[i])
    d <- list(lat = puntos$lat[j], lon = puntos$lon[j])
    if (any(is.na(c(o$lat, d$lat)))) {
      return(data.frame(origen = puntos$texto[i], destino = puntos$texto[j], ok = FALSE,
                        causa = "direccion no geocodificada", duracion_min = NA, transbordos = NA))
    }
    r <- tryCatch(calcular_colectivo_seguro(o, d, franja = franja, factor_sesgo = factor_sesgo,
                                            k_alternativas = 1), error = function(e) e)
    if (inherits(r, "error")) {
      return(data.frame(origen = puntos$texto[i], destino = puntos$texto[j], ok = FALSE,
                        causa = conditionMessage(r), duracion_min = NA, transbordos = NA))
    }
    data.frame(origen = puntos$texto[i], destino = puntos$texto[j], ok = TRUE, causa = "",
               duracion_min = r[[1]]$duracion_min, transbordos = r[[1]]$transbordos)
  })
  do.call(rbind, filas)
}

if (sys.nframe() == 0) {
  puntos <- geocodificar_prueba()
  message(sum(!is.na(puntos$lat)), " de ", nrow(puntos), " direcciones geocodificadas.")
  res <- probar_pares(puntos)
  write.csv(res, RUTA_PRUEBA, row.names = FALSE)
  cat(sprintf("Pares probados: %d. Con recorrido: %d (%.1f %%).\n",
              nrow(res), sum(res$ok), 100 * mean(res$ok)))
  if (any(!res$ok)) {
    cat("Fallos:\n")
    print(res[!res$ok, c("origen", "destino", "causa")], right = FALSE)
  }
}
