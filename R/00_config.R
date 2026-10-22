# ============================================================
# 00_config.R
# Configuración general del prototipo: motor de ruteo, pesos
# de la Eficiencia global (E) y parámetros de la grilla de riesgo.
# ============================================================

# --- Paquetes requeridos ------------------------------------
paquetes_requeridos <- c(
  "sf", "osrm", "tidygeocoder", "leaflet", "shiny",
  "dplyr", "purrr", "stats", "ggplot2"
)

instalar_faltantes <- function(paquetes) {
  faltantes <- paquetes[!paquetes %in% rownames(installed.packages())]
  if (length(faltantes) > 0) {
    install.packages(faltantes, repos = "https://cloud.r-project.org")
  }
}
instalar_faltantes(paquetes_requeridos)
invisible(lapply(paquetes_requeridos, library, character.only = TRUE))

# --- Motor de ruteo ------------------------------------------
# "osrm"   -> servidor público de demostración OSRM (gratuito, sin API key)
# "google" -> Google Routes API (requiere GOOGLE_MAPS_API_KEY con billing habilitado)
MOTOR_RUTEO <- "osrm"

# Servidor OSRM público (cobertura mundial, perfil de auto "driving")
options(osrm.server = "https://router.project-osrm.org/")
options(osrm.profile = "driving")

# Si se usa Google, la clave se lee de una variable de entorno
# (nunca hardcodear la clave en el script):
#   Sys.setenv(GOOGLE_MAPS_API_KEY = "tu_clave_aqui")
GOOGLE_MAPS_API_KEY <- Sys.getenv("GOOGLE_MAPS_API_KEY", unset = NA)

# Caminata: Mapbox Directions (perfil "walking"). La clave se lee del entorno
# (~/.Renviron, nunca dentro del proyecto):  MAPBOX_TOKEN=pk.xxxxx
MAPBOX_TOKEN <- Sys.getenv("MAPBOX_TOKEN", unset = NA)

# Caminata preferida: OSRM peatonal local (Docker, perfil foot, mapa de Argentina).
# Gratis y sin límites. Si no está levantado, se usa Mapbox.
OSRM_PEATONAL_SERVER <- "http://127.0.0.1:5001/"

# --- Pesos de la Eficiencia global E (definidos en la Introducción) ---
ALPHA_TIEMPO       <- 0.5   # peso de la variable A (tiempo)
BETA_RIESGO        <- 0.3   # peso de la variable B (riesgo)
GAMMA_EFICIENCIA   <- 0.2   # peso de la variable C (eficiencia computacional)
stopifnot(abs(ALPHA_TIEMPO + BETA_RIESGO + GAMMA_EFICIENCIA - 1) < 1e-9)

# --- Parámetros de la grilla de riesgo ------------------------
TAMANO_CELDA_M     <- 250   # lado de celda en metros
CRS_GEOGRAFICO     <- 4326  # WGS84 (lat/lon) - formato de origen de los datos
CRS_PROYECTADO     <- 5347  # POSGAR 2007 / UTM zona 21S - para cálculos métricos

# --- Bounding box aproximado de CABA (para simulación y fallback) ---
CABA_BBOX <- c(xmin = -58.5315, ymin = -34.7054, xmax = -58.3353, ymax = -34.5265)

# --- Tiempo de respuesta máximo aceptable (para variable C) ---
TIEMPO_RESPUESTA_MAXIMO_SEG <- 5

# --- Carpeta de datos (funciona desde la raíz y desde R/) -----
RUTA_DATOS <- if (dir.exists("data")) {
  "data"
} else if (dir.exists("../data")) {
  "../data"
} else {
  "data"
}

# --- Datos delictivos (Introducción, sección 2) ---------------
# Robos y hurtos según el documento (1.064.417 registros 2016-2025).
TIPOS_DELITO_RIESGO <- c("Robo", "Hurto")
# 2020-2021 excluidos por pandemia (no representativos).
ANIOS_EXCLUIDOS     <- c(2020L, 2021L)
# Partición cronológica: entrenamiento / ajuste (2024) / prueba final (2025).
ANIOS_ENTRENAMIENTO <- c(2016L:2019L, 2022L:2023L)
ANIO_AJUSTE        <- 2024L
ANIO_PRUEBA        <- 2025L
# Franja horaria nocturna (20:00 a 05:59) para la ponderación horaria.
FRANJAS_NOCTURNAS  <- c(20L:23L, 0L:5L)

# Candidatos de ajuste (se eligen con el año de ajuste, no con 2025)
TAMANOS_CELDA_CANDIDATOS <- c(100, 250, 500)
PESO_NOCTURNO_CANDIDATOS <- c(1, 1.5, 2)
