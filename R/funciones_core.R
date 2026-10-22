# ============================================================
# funciones_core.R
# Geocodificación, generación de rutas candidatas, cálculo de
# exposición al riesgo y de las variables A, B, C, E.
# ============================================================

source(if (file.exists("00_config.R")) "00_config.R" else "R/00_config.R")
# geocodificar_direccion() vive en geocodificacion.R (USIG, Georef, links de Google Maps, coordenadas)
source(if (file.exists("geocodificacion.R")) "geocodificacion.R" else "R/geocodificacion.R")

#' Obtiene la ruta más rápida entre dos puntos según el medio de transporte.
#' @param origen,destino list(lat=, lon=)
#' @param via punto de paso opcional list(lat=, lon=) para forzar un desvío
#' @param modo "auto" (OSRM / Google) o "caminando" (Mapbox)
#' @return objeto sf (LINESTRING) con columnas duration (min) y distance (km)
obtener_ruta <- function(origen, destino, via = NULL, modo = "auto") {
  if (modo == "caminando") {
    return(obtener_ruta_caminando(origen, destino, via))
  }

  if (MOTOR_RUTEO == "google") {
    if (is.na(GOOGLE_MAPS_API_KEY)) {
      stop("MOTOR_RUTEO = 'google' pero no se encontró GOOGLE_MAPS_API_KEY en el entorno.")
    }
    return(obtener_ruta_google(origen, destino, via))
  }

  # --- OSRM (default) ---
  puntos <- data.frame(
    id = c("origen", if (!is.null(via)) "via", "destino"),
    lon = c(origen$lon, if (!is.null(via)) via$lon, destino$lon),
    lat = c(origen$lat, if (!is.null(via)) via$lat, destino$lat)
  )
  loc_sf <- sf::st_as_sf(puntos, coords = c("lon", "lat"), crs = CRS_GEOGRAFICO)

  ruta <- osrm::osrmRoute(loc = loc_sf, overview = "full")
  ruta
}

#' Indica si el OSRM peatonal local responde (nearest es una consulta mínima).
servidor_peatonal_disponible <- function() {
  tryCatch({
    r <- httr::GET(paste0(OSRM_PEATONAL_SERVER, "nearest/v1/foot/-58.3816,-34.6037"),
                   httr::timeout(3))
    httr::status_code(r) == 200
  }, error = function(e) FALSE)
}

#' Ruta a pie con Mapbox Directions (perfil "walking"). Devuelve el mismo formato
#' que obtener_ruta(): duration en minutos, distance en km.
obtener_ruta_caminando <- function(origen, destino, via = NULL) {
  if (servidor_peatonal_disponible()) {
    puntos <- if (is.null(via)) list(origen, destino) else list(origen, via, destino)
    puntos_df <- data.frame(
      id  = seq_along(puntos),
      lon = vapply(puntos, function(p) p$lon, numeric(1)),
      lat = vapply(puntos, function(p) p$lat, numeric(1))
    )
    loc_sf <- sf::st_as_sf(puntos_df, coords = c("lon", "lat"), crs = CRS_GEOGRAFICO)
    return(osrm::osrmRoute(loc = loc_sf, overview = "full",
                           osrm.server = OSRM_PEATONAL_SERVER, osrm.profile = "foot"))
  }

  if (is.na(MAPBOX_TOKEN)) {
    stop("No hay ruteo peatonal: levantá el OSRM peatonal local (Docker) o definí MAPBOX_TOKEN en ~/.Renviron.")
  }

  puntos <- if (is.null(via)) list(origen, destino) else list(origen, via, destino)
  coords <- paste(vapply(puntos, function(p) sprintf("%f,%f", p$lon, p$lat), character(1)),
                  collapse = ";")
  url <- sprintf(
    "https://api.mapbox.com/directions/v5/mapbox/walking/%s?geometries=geojson&overview=full&access_token=%s",
    coords, MAPBOX_TOKEN
  )

  respuesta <- jsonlite::fromJSON(url, simplifyVector = FALSE)
  if (!identical(respuesta$code, "Ok")) {
    stop("Mapbox devolvió: ", respuesta$code, " ", respuesta$message)
  }

  ruta <- respuesta$routes[[1]]
  coords_mat <- do.call(rbind, lapply(ruta$geometry$coordinates, unlist))  # lon, lat
  sf::st_sf(
    duration = ruta$duration / 60,    # segundos -> minutos
    distance = ruta$distance / 1000,  # metros -> km
    geometry = sf::st_sfc(sf::st_linestring(coords_mat), crs = CRS_GEOGRAFICO)
  )
}

#' Alternativa con Google Routes API (requiere httr y clave con billing activo).
obtener_ruta_google <- function(origen, destino, via = NULL) {
  waypoints <- if (!is.null(via)) {
    sprintf("&waypoints=%f,%f", via$lat, via$lon)
  } else ""

  url <- sprintf(
    "https://maps.googleapis.com/maps/api/directions/json?origin=%f,%f&destination=%f,%f%s&key=%s",
    origen$lat, origen$lon, destino$lat, destino$lon, waypoints, GOOGLE_MAPS_API_KEY
  )
  resp <- httr::GET(url)
  contenido <- httr::content(resp, as = "parsed")

  if (contenido$status != "OK") {
    stop("Google Directions API devolvió estado: ", contenido$status)
  }

  ruta_puntos <- googlePolylines::decode(contenido$routes[[1]]$overview_polyline$points)[[1]]
  linea <- sf::st_linestring(as.matrix(ruta_puntos[, c("lon", "lat")]))
  ruta_sf <- sf::st_sf(
    duration = contenido$routes[[1]]$legs[[1]]$duration$value / 60,  # minutos
    distance = contenido$routes[[1]]$legs[[1]]$distance$value / 1000, # km
    geometry = sf::st_sfc(linea, crs = CRS_GEOGRAFICO)
  )
  ruta_sf
}

#' Identifica las celdas de mayor riesgo atravesadas por una ruta y
#' propone hasta `n_desvios` puntos de paso fuera de esas celdas,
#' para generar rutas candidatas alternativas.
proponer_waypoints_desvio <- function(ruta_sf, grilla_riesgo, n_desvios = 2) {
  ruta_proy <- sf::st_transform(ruta_sf, crs = CRS_PROYECTADO)
  celdas_cruzadas <- sf::st_filter(grilla_riesgo, ruta_proy)

  if (nrow(celdas_cruzadas) == 0) return(list())

  celdas_riesgosas <- celdas_cruzadas[order(-celdas_cruzadas$riesgo), ]
  celdas_riesgosas <- head(celdas_riesgosas, n_desvios)

  # Para cada celda riesgosa, se propone un punto a ~300m de su centroide,
  # en dirección opuesta a la concentración de riesgo local (heurística simple:
  # se desplaza hacia la celda vecina de menor riesgo).
  centroides <- sf::st_centroid(celdas_riesgosas)
  centroides_geo <- sf::st_transform(centroides, crs = CRS_GEOGRAFICO)
  coords <- sf::st_coordinates(centroides_geo)

  lapply(seq_len(nrow(coords)), function(i) {
    list(lat = coords[i, "Y"] + 0.0027, lon = coords[i, "X"] + 0.0027) # ~300m aprox
  })
}

#' Calcula la exposición al riesgo acumulada de una ruta, ponderada
#' por la longitud del segmento dentro de cada celda de la grilla.
calcular_riesgo_ruta <- function(ruta_sf, grilla_riesgo) {
  ruta_proy <- sf::st_transform(ruta_sf, crs = CRS_PROYECTADO)
  interseccion <- suppressWarnings(sf::st_intersection(grilla_riesgo, ruta_proy))

  if (nrow(interseccion) == 0) return(0)

  longitudes <- as.numeric(sf::st_length(sf::st_geometry(interseccion)))
  sum(interseccion$riesgo * longitudes, na.rm = TRUE)
}

#' Elige, entre las rutas candidatas, la que mejor resuelve el problema
#' intrínseco (reducir riesgo sin encarecer demasiado el tiempo). Esta
#' es lógica de ingeniería del algoritmo, no una variable de evaluación
#' académica — esas (A, B, C) se calculan aparte, a nivel de sistema,
#' en `calcular_variables_evaluacion()`.
#' @param incremento_tiempo_max_pct tope de encarecimiento de tiempo aceptado (ej. 0.25 = 25%)
seleccionar_mejor_candidata <- function(rutas, grilla_riesgo, incremento_tiempo_max_pct = 0.25) {
  duraciones <- vapply(rutas, function(r) r$duration[1], numeric(1))
  riesgos    <- vapply(rutas, calcular_riesgo_ruta, numeric(1), grilla_riesgo = grilla_riesgo)

  t_min <- min(duraciones)
  aceptables <- which(duraciones <= t_min * (1 + incremento_tiempo_max_pct))

  idx_optima <- aceptables[which.min(riesgos[aceptables])]

  data.frame(
    id_ruta = seq_along(rutas),
    duracion_min = duraciones,
    riesgo_abs = riesgos
  ) -> tabla

  list(tabla = tabla, idx_optima = idx_optima)
}

#' Variable A (Eficacia): reducción de riesgo lograda por la ruta elegida
#' respecto de la ruta más rápida (línea de base), para UN trayecto evaluado.
calcular_eficacia <- function(riesgo_base, riesgo_optima) {
  if (riesgo_base <= 0) return(0)  # sin riesgo que reducir, no hay eficacia que medir
  max(0, (riesgo_base - riesgo_optima) / riesgo_base)
}

#' Variable B (Tiempo de respuesta): qué tan rápido respondió el PROTOTIPO
#' (no la duración del viaje), medida en segundos de reloj.
calcular_tiempo_respuesta <- function(t_respuesta_seg, maximo_aceptable = TIEMPO_RESPUESTA_MAXIMO_SEG) {
  min(1, maximo_aceptable / t_respuesta_seg)
}

#' Variable C (Robustez de geocodificación): se corre UNA sola vez sobre
#' un set de direcciones reales con formatos informales/incompletos, no
#' por cada consulta del usuario.
#' @param direcciones_prueba data.frame con columnas: texto, lat_real, lon_real
test_robustez_geocodificacion <- function(direcciones_prueba, radio_tolerancia_m = 100) {
  exitos <- vapply(seq_len(nrow(direcciones_prueba)), function(i) {
    geo <- geocodificar_direccion(direcciones_prueba$texto[i])
    if (is.null(geo)) return(FALSE)

    punto_obtenido <- sf::st_sfc(sf::st_point(c(geo$lon, geo$lat)), crs = CRS_GEOGRAFICO)
    punto_real <- sf::st_sfc(
      sf::st_point(c(direcciones_prueba$lon_real[i], direcciones_prueba$lat_real[i])),
      crs = CRS_GEOGRAFICO
    )
    distancia_m <- as.numeric(sf::st_distance(
      sf::st_transform(punto_obtenido, CRS_PROYECTADO),
      sf::st_transform(punto_real, CRS_PROYECTADO)
    ))
    distancia_m <= radio_tolerancia_m
  }, logical(1))

  mean(exitos)  # ya acotado 0-1 por construcción
}

#' Tabla de métricas de ruteo (duración/riesgo) por candidata.
#' Mantenida por compatibilidad con el flujo de selección; NO son las
#' variables A/B/C de evaluación académica (ver nota arriba).
evaluar_rutas_candidatas <- function(rutas, grilla_riesgo, valor_c = NA) {
  duraciones <- vapply(rutas, function(r) r$duration[1], numeric(1))
  riesgos    <- vapply(rutas, calcular_riesgo_ruta, numeric(1), grilla_riesgo = grilla_riesgo)

  data.frame(
    id_ruta   = seq_along(rutas),
    duracion_min = duraciones,
    riesgo_abs   = riesgos
  )
}

#' Flujo completo: geocodifica, genera candidatas, elige la mejor y
#' calcula las variables de evaluación A (Eficacia) y B (Tiempo de
#' respuesta) para ESE trayecto. C (Robustez de geocodificación) se
#' calcula aparte, una sola vez, con `test_robustez_geocodificacion()`
#' sobre un set de prueba — no depende de una consulta puntual.
calcular_ruta_optima <- function(direccion_origen, direccion_destino, grilla_riesgo,
                                 modo = "auto") {
  t0 <- Sys.time()

  origen  <- geocodificar_direccion(direccion_origen)
  destino <- geocodificar_direccion(direccion_destino)
  if (is.null(origen) || is.null(destino)) {
    stop("No se pudo geocodificar una de las direcciones ingresadas.")
  }

  ruta_directa <- obtener_ruta(origen, destino, modo = modo)
  waypoints <- proponer_waypoints_desvio(ruta_directa, grilla_riesgo, n_desvios = 2)

  rutas_candidatas <- c(
    list(ruta_directa),
    lapply(waypoints, function(wp) obtener_ruta(origen, destino, via = wp, modo = modo))
  )

  seleccion <- seleccionar_mejor_candidata(rutas_candidatas, grilla_riesgo)
  tabla_metricas <- seleccion$tabla
  idx_optima <- seleccion$idx_optima

  t_respuesta_seg <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  variable_a <- calcular_eficacia(
    riesgo_base = tabla_metricas$riesgo_abs[1],
    riesgo_optima = tabla_metricas$riesgo_abs[idx_optima]
  )
  variable_b <- calcular_tiempo_respuesta(t_respuesta_seg)

  list(
    origen = origen,
    destino = destino,
    ruta_directa = ruta_directa,
    ruta_optima = rutas_candidatas[[idx_optima]],
    tabla_metricas = tabla_metricas,
    idx_optima = idx_optima,
    tiempo_respuesta_seg = t_respuesta_seg,
    A_eficacia = variable_a,
    B_tiempo_respuesta = variable_b
  )
}
