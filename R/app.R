# ============================================================
# app.R
# Prototipo Beta - Optimizador de rutas urbanas en CABA con
# prevención de exposición al riesgo delictivo histórico.
#
# Interfaz tipo Google Maps: panel de búsqueda a la izquierda,
# medio de transporte, hora de salida y tres rutas (más rápida,
# óptima y más segura) en modo transporte público.
#
# Ejecutar con: shiny::runApp("R")
# (o abrir este archivo en RStudio y presionar "Run App")
# ============================================================

source("00_config.R")
source("01_preparar_riesgo.R")
source("funciones_core.R")
source("02_simulacion_resultados.R")  # provee construir_set_prueba_geocodificacion()
source("transporte.R")                # colectivos con riesgo: frontera Pareto (modo "Transporte")

TZ_APP <- "America/Argentina/Buenos_Aires"

#' Formatea una duración en minutos: "46 min" o "1 h 12 min".
formatear_duracion <- function(minutos) {
  m <- round(minutos)
  if (m < 60) sprintf("%d min", m) else sprintf("%d h %02d min", m %/% 60, m %% 60)
}

# Grafo de colectivos: se arma al iniciar la app (unos 20 s) para que el primer cálculo sea rápido.
invisible(tryCatch(obtener_grafo_colectivos(), error = function(e) {
  message("Colectivos no disponibles: ", conditionMessage(e))
  NULL
}))

#' Colores de cada ruta (más rápida, óptima, más segura) y de las líneas de colectivo.
COLORES_ROL <- c(rapida = "#1a73e8", optima = "#188038", segura = "#d93025")
COLORES_LINEAS <- c("#d93025", "#e37400", "#188038", "#007b83", "#1a73e8",
                    "#9334e6", "#c2185b", "#5f6368", "#795548")

#' Color estable por línea (el mismo número de línea siempre tiene el mismo color).
color_linea <- function(linea) {
  COLORES_LINEAS[(sum(utf8ToInt(as.character(linea))) %% length(COLORES_LINEAS)) + 1]
}

#' Hora de salida: "ahora" o la hora escrita (HH:MM) del día de hoy.
hora_salida <- function(cuando, hora_txt) {
  ahora <- Sys.time()
  if (!identical(cuando, "hora") || !nzchar(trimws(hora_txt %||% ""))) return(ahora)
  hora_txt <- trimws(hora_txt)
  if (!grepl("^([01]?[0-9]|2[0-3]):[0-5][0-9]$", hora_txt)) stop("La hora debe tener formato HH:MM.")
  partes <- as.integer(strsplit(hora_txt, ":")[[1]])
  as.POSIXct(sprintf("%s %02d:%02d:00", format(ahora, "%Y-%m-%d", tz = TZ_APP), partes[1], partes[2]),
             tz = TZ_APP)
}

#' Elige las tres rutas de la frontera Pareto (`op` viene ordenado por tiempo):
#'   - más rápida: menor tiempo;
#'   - más segura: menor exposición;
#'   - óptima: menor suma de tiempo y exposición normalizados entre 0 y 1.
#' Si dos roles caen en la misma ruta, la tarjeta muestra los dos nombres.
seleccionar_tres_rutas <- function(op) {
  norma <- function(x) {
    r <- max(x) - min(x)
    if (r < 1e-9) rep(0, length(x)) else (x - min(x)) / r
  }
  roles <- c(rapida = 1L,
             optima = which.min(norma(op$duracion_min) + norma(op$exposicion)),
             segura = which.min(op$exposicion))
  etiquetas <- c(rapida = "Más rápida", optima = "Óptima", segura = "Más segura")
  idx <- unique(unname(roles))
  data.frame(
    idx = idx,
    etiqueta = vapply(idx, function(i) paste(etiquetas[names(roles)[roles == i]], collapse = " · "),
                      character(1)),
    color = vapply(idx, function(i) COLORES_ROL[[names(roles)[roles == i][1]]], character(1)),
    stringsAsFactors = FALSE
  )
}

#' Calcula la frontera de colectivo para dos textos de dirección y la hora de salida.
calcular_transporte_app <- function(texto_origen, texto_destino, salida) {
  o <- geocodificar_direccion(texto_origen)
  d <- geocodificar_direccion(texto_destino)
  if (is.null(o)) stop("No se pudo ubicar el origen dentro de AMBA.")
  if (is.null(d)) stop("No se pudo ubicar el destino dentro de AMBA.")
  franja <- franja_actual(format(salida, "%H", tz = TZ_APP))
  frontera <- frontera_pareto_transporte(list(lat = o$lat, lon = o$lon),
                                         list(lat = d$lat, lon = d$lon), franja = franja)
  list(tipo = "transporte", origen = o, destino = d, frontera = frontera, franja = franja,
       salida = salida, elegidas = seleccionar_tres_rutas(frontera$opciones))
}

#' Dibuja las tres rutas elegidas, como Google Maps: a pie punteado y gris; en colectivo,
#' cada línea con su color. La ruta seleccionada va gruesa; las demás, finas y translúcidas.
dibujar_transporte <- function(mapa, res, sel) {
  el <- res$elegidas
  orden <- order(el$idx == sel)   # la seleccionada se dibuja al final, encima
  for (k in orden) {
    i <- el$idx[k]
    pts <- res$frontera$rutas[[i]]$puntos
    pts <- pts[!is.na(pts$lat), ]
    activa <- is.null(sel) || identical(sel, i)
    peso <- if (activa) 7 else 4
    opacidad <- if (activa) 0.95 else 0.4
    # Tramos consecutivos del mismo modo y línea: cada uno se dibuja aparte.
    # El punto de llegada del tramo siguiente se repite para que no queden huecos.
    tramos_mapa <- rle(paste(pts$modo, pts$linea))
    fin <- cumsum(tramos_mapa$lengths)
    ini <- c(1, fin[-length(fin)])
    for (s in seq_along(ini)) {
      sub_pts <- pts[ini[s]:min(fin[s] + 1, nrow(pts)), ]
      # El modo y la línea del tramo los define su último punto (el origen no tiene modo: va a pie)
      a_pie <- is.na(pts$modo[fin[s]]) || pts$modo[fin[s]] == "walk"
      color <- if (a_pie) "#5f6368" else color_linea(pts$linea[fin[s]])
      etiqueta <- if (a_pie) "A pie" else sprintf("Línea %s", pts$linea[fin[s]])
      mapa <- leaflet::addPolylines(mapa, lng = sub_pts$lon, lat = sub_pts$lat, color = color,
                                    weight = peso, opacity = opacidad,
                                    dashArray = if (a_pie) "2,8" else NULL,
                                    label = sprintf("%s · %s: %s", el$etiqueta[k], etiqueta,
                                                    formatear_duracion(res$frontera$opciones$duracion_min[i])),
                                    layerId = paste0("ruta_", i, "_", s))
    }
  }
  mapa
}

#' Dibuja las dos rutas de auto o a pie: directa y óptima.
dibujar_auto <- function(mapa, res) {
  mapa |>
    leaflet::addPolylines(
      data = res$ruta_directa, color = COLORES_ROL[["rapida"]], weight = 5, opacity = 0.9,
      label = "Ruta más rápida", group = "Ruta directa"
    ) |>
    leaflet::addPolylines(
      data = res$ruta_optima, color = COLORES_ROL[["optima"]], weight = 5, opacity = 0.9,
      label = "Ruta óptima (riesgo reducido)", group = "Ruta óptima"
    ) |>
    leaflet::addLayersControl(
      overlayGroups = c("Riesgo", "Ruta directa", "Ruta óptima"),
      options = leaflet::layersControlOptions(collapsed = FALSE)
    )
}

#' Tarjeta de una ruta: rol, tiempo, horario de salida y llegada, detalle y chips de tramos.
tarjeta_ruta <- function(etiqueta, color, duracion_min, salida, detalle, chips = NULL,
                         detalle_tramos = NULL, id = NULL, activa = FALSE) {
  llegada <- salida + 60 * duracion_min
  onclick <- if (!is.null(id)) sprintf("Shiny.setInputValue('ruta_sel', %d, {priority: 'event'})", id)
  shiny::tags$div(
    class = if (activa) "tarjeta activa" else "tarjeta",
    onclick = onclick,
    shiny::tags$div(class = "rol",
                    shiny::tags$span(class = "barra", style = sprintf("background:%s", color)),
                    etiqueta),
    shiny::tags$div(
      shiny::tags$span(class = "tiempo", formatear_duracion(duracion_min)),
      shiny::tags$span(class = "horas", sprintf("%s → %s", format(salida, "%H:%M", tz = TZ_APP),
                                                format(llegada, "%H:%M", tz = TZ_APP)))
    ),
    shiny::tags$div(class = "detalle", detalle),
    chips,
    detalle_tramos
  )
}

#' Chips de la ruta: una por línea de colectivo y un gris por cada caminata.
chips_tramos <- function(tramos) {
  shiny::tags$div(lapply(seq_len(nrow(tramos)), function(k) {
    t <- tramos[k, ]
    if (t$tipo == "colectivo") {
      shiny::tags$span(class = "chip", style = sprintf("background:%s", color_linea(t$linea)),
                       title = sprintf("%s → %s (%d paradas, %s)", t$desde, t$hasta, t$paradas,
                                       formatear_duracion(t$minutos)),
                       t$linea)
    } else {
      etiqueta <- if (t$tipo == "a pie") "Caminar" else "Caminar (transbordo)"
      shiny::tags$span(class = "chip chip-caminata", sprintf("%s %s", etiqueta, formatear_duracion(t$minutos)))
    }
  }))
}

#' Lista detallada de tramos, plegable dentro de cada tarjeta.
detalle_tramos <- function(tramos) {
  filas <- lapply(seq_len(nrow(tramos)), function(k) {
    t <- tramos[k, ]
    texto <- if (t$tipo == "colectivo") {
      sprintf("Línea %s: %s → %s (%d paradas, %s)", t$linea, t$desde, t$hasta, t$paradas,
              formatear_duracion(t$minutos))
    } else {
      sprintf("%s: %s → %s (%s)", t$tipo, t$desde, t$hasta, formatear_duracion(t$minutos))
    }
    shiny::tags$li(texto)
  })
  shiny::tags$details(class = "tramos", shiny::tags$summary("Tramos"), shiny::tags$ul(filas))
}

#' Panel de resultados en modo transporte: tres tarjetas (más rápida, óptima, más segura).
tabla_transporte <- function(res, sel) {
  op <- res$frontera$opciones
  tarjetas <- lapply(seq_len(nrow(res$elegidas)), function(k) {
    el <- res$elegidas[k, ]
    i <- el$idx
    tarjeta_ruta(
      etiqueta = el$etiqueta, color = el$color, duracion_min = op$duracion_min[i], salida = res$salida,
      detalle = sprintf("Exposición %.1f · %d transbordo(s) · caminata %.0f min",
                        op$exposicion[i], op$transbordos[i], op$caminata_min[i]),
      chips = chips_tramos(res$frontera$rutas[[i]]$tramos),
      detalle_tramos = detalle_tramos(res$frontera$rutas[[i]]$tramos),
      id = i, activa = identical(sel, i)
    )
  })
  shiny::tagList(
    shiny::tags$p(class = "nota", sprintf("Salida %s · franja %s.", format(res$salida, "%H:%M", tz = TZ_APP), res$franja)),
    shiny::tags$p(class = "aviso", "Tiempos estimativos: horarios del GTFS de 2019 (no vigentes) y trazados del RMBA de 2023. No es tiempo real."),
    if (nrow(res$elegidas) == 1) shiny::tags$p(class = "nota", "Para este viaje hay una sola ruta no dominada."),
    tarjetas,
    shiny::tags$p(class = "nota", "Tocá una ruta para verla en el mapa.")
  )
}

#' Panel de resultados en auto o a pie: ruta más rápida y óptima, más los indicadores A, B, C y E.
tabla_auto <- function(res) {
  m <- res$tabla_metricas[res$idx_optima, ]
  base <- res$tabla_metricas[1, ]
  mismo <- res$idx_optima == 1
  eficiencia_e <- ALPHA_TIEMPO * res$A_eficacia + BETA_RIESGO * res$B_tiempo_respuesta +
    GAMMA_EFICIENCIA * VALOR_C_GLOBAL

  tarjetas <- list(tarjeta_ruta(
    etiqueta = if (mismo) "Más rápida · Óptima" else "Más rápida", color = COLORES_ROL[["rapida"]],
    duracion_min = base$duracion_min, salida = res$salida,
    detalle = sprintf("Exposición %.1f", base$riesgo_abs)
  ))
  if (!mismo) {
    tarjetas <- c(tarjetas, list(tarjeta_ruta(
      etiqueta = "Óptima (menos riesgo)", color = COLORES_ROL[["optima"]],
      duracion_min = m$duracion_min, salida = res$salida,
      detalle = sprintf("Exposición %.1f (la más rápida: %.1f)", m$riesgo_abs, base$riesgo_abs)
    )))
  }

  shiny::tagList(
    shiny::tags$p(class = "nota", "Auto y a pie muestran dos rutas. Las tres opciones (más rápida, óptima y más segura) están en Transporte."),
    tarjetas,
    shiny::tags$details(
      class = "tramos",
      shiny::tags$summary("Puntos y variables de evaluación"),
      shiny::tags$h5("Puntos normalizados"),
      shiny::tags$ul(
        shiny::tags$li(sprintf("Origen: %s (%s)", res$origen$direccion, res$origen$fuente %||% "")),
        shiny::tags$li(sprintf("Destino: %s (%s)", res$destino$direccion, res$destino$fuente %||% ""))
      ),
      shiny::tags$p(shiny::em("Variables de evaluación del prototipo:")),
      shiny::tags$ul(
        shiny::tags$li(sprintf("A (Eficacia): %.2f", res$A_eficacia)),
        shiny::tags$li(sprintf("B (Tiempo de respuesta): %.2f  (%.1f s reales)", res$B_tiempo_respuesta, res$tiempo_respuesta_seg)),
        shiny::tags$li(sprintf("C (Robustez de geocodificación): %.2f", VALOR_C_GLOBAL)),
        shiny::tags$li(shiny::strong(sprintf("E (Eficiencia global): %.2f", eficiencia_e)))
      )
    )
  )
}

# --- Carga de la grilla de riesgo (una sola vez, al iniciar la app) ---
ruta_grilla <- file.path(RUTA_DATOS, "grilla_riesgo.rds")
grilla_riesgo_global <- if (file.exists(ruta_grilla)) {
  readRDS(ruta_grilla)
} else {
  obtener_grilla_riesgo()
}
grilla_riesgo_geo <- sf::st_transform(grilla_riesgo_global, crs = CRS_GEOGRAFICO)

# Tamaño real de celda: el que quedó en los parámetros de la grilla (500 m con datos reales)
TAMANO_GRILLA <- attr(grilla_riesgo_global, "parametros")$tamano_celda
if (is.null(TAMANO_GRILLA)) TAMANO_GRILLA <- TAMANO_CELDA_M

# Variable C (Robustez de geocodificación) se calcula una sola vez al
# iniciar la app, sobre el set de prueba — no depende de la consulta del usuario.
VALOR_C_GLOBAL <- tryCatch(
  test_robustez_geocodificacion(construir_set_prueba_geocodificacion()),
  error = function(e) NA
)

# ============================================================
# UI
# ============================================================
CSS_APP <- "
html, body { height: 100%; margin: 0; }
.container-fluid { padding: 0; }
.panel-ruta {
  position: fixed; top: 0; left: 0; bottom: 0; width: 400px; overflow-y: auto;
  background: #fff; padding: 14px 16px 24px; box-shadow: 0 0 8px rgba(0,0,0,.25);
  z-index: 1000; font-family: system-ui, -apple-system, sans-serif; color: #202124;
}
.panel-ruta .form-group { margin-bottom: 8px; }
.panel-ruta .titulo { font-size: 18px; font-weight: 600; margin: 4px 0 10px; }
.panel-ruta .shiny-input-container { width: 100%; }
.panel-ruta .radio-inline { margin-right: 10px; }
.panel-ruta .boton-ancho { width: 100%; margin: 6px 0 4px; border-radius: 20px; font-weight: 600; }
.mapa-full { position: fixed; top: 0; left: 400px; right: 0; bottom: 0; }
.mapa-full .html-widget, .mapa-full .leaflet-container { height: 100% !important; }
.tarjeta {
  border: 1px solid #dadce0; border-radius: 10px; padding: 10px 12px; margin: 8px 0; cursor: pointer;
}
.tarjeta:hover { background: #f8f9fa; }
.tarjeta.activa { border: 2px solid #1a73e8; box-shadow: 0 1px 4px rgba(0,0,0,.2); }
.tarjeta .rol { font-weight: 600; font-size: 14px; }
.tarjeta .barra { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }
.tarjeta .tiempo { font-size: 20px; font-weight: 600; margin-right: 8px; }
.tarjeta .horas { color: #5f6368; font-size: 13px; }
.tarjeta .detalle { color: #5f6368; font-size: 13px; margin: 2px 0 6px; }
.chip {
  display: inline-block; color: #fff; border-radius: 4px; padding: 1px 6px; margin: 2px 4px 2px 0;
  font-weight: 600; font-size: 12px;
}
.chip-caminata { background: #eceff1; color: #202124; font-weight: normal; }
.nota { color: #5f6368; font-size: 12.5px; margin: 6px 0; }
.aviso { background: #fef7e0; color: #7a4f01; border-radius: 6px; padding: 6px 8px; font-size: 12.5px; margin: 6px 0; }
.tramos { font-size: 13px; margin-top: 4px; }
.tramos summary { cursor: pointer; color: #1a73e8; }
@media (max-width: 760px) {
  .panel-ruta { position: relative; width: auto; height: 46vh; }
  .mapa-full { position: relative; left: 0; height: 54vh; }
}
"

ui <- shiny::fluidPage(
  shiny::tags$head(shiny::tags$style(shiny::HTML(CSS_APP))),
  shiny::div(
    class = "panel-ruta",
    shiny::div(class = "titulo", "Optimizador de rutas CABA (Beta)"),
    shiny::textInput("direccion_origen", NULL, placeholder = "Elegí el origen"),
    shiny::textInput("direccion_destino", NULL, placeholder = "Elegí el destino"),
    shiny::radioButtons("modo", NULL,
                        choices = c("Auto" = "auto", "A pie" = "caminando", "Transporte" = "transporte"),
                        selected = "transporte", inline = TRUE),
    shiny::radioButtons("cuando", NULL,
                        choices = c("Salir ahora" = "ahora", "Salir a las" = "hora"),
                        selected = "ahora", inline = TRUE),
    shiny::conditionalPanel(
      condition = "input.cuando == 'hora'",
      shiny::textInput("hora", NULL, placeholder = "HH:MM (ej. 08:30)")
    ),
    shiny::actionButton("calcular", "Buscar rutas", class = "btn-primary boton-ancho"),
    shiny::helpText("Acepta direcciones, coordenadas o links de Google Maps. También podés hacer clic en el mapa:"),
    shiny::radioButtons("clic_mapa", NULL,
                        choices = c("No usar" = "no", "Define origen" = "origen", "Define destino" = "destino"),
                        selected = "no", inline = TRUE),
    shiny::uiOutput("tabla_resultado")
  ),
  shiny::div(
    class = "mapa-full",
    leaflet::leafletOutput("mapa", width = "100%", height = "100%")
  )
)

# ============================================================
# SERVER
# ============================================================
server <- function(input, output, session) {

  # Ruta seleccionada en modo transporte (índice en la frontera)
  seleccion <- shiny::reactiveVal(NULL)

  resultado <- shiny::eventReactive(input$calcular, {
    shiny::req(input$direccion_origen, input$direccion_destino)

    shiny::withProgress(message = "Buscando rutas...", {
      tryCatch({
        salida <- hora_salida(input$cuando, input$hora)
        if (identical(input$modo, "transporte")) {
          calcular_transporte_app(input$direccion_origen, input$direccion_destino, salida = salida)
        } else {
          res <- calcular_ruta_optima(
            input$direccion_origen,
            input$direccion_destino,
            grilla_riesgo_global,
            modo = input$modo
          )
          res$salida <- salida
          res
        }
      }, error = function(e) {
        shiny::showNotification(paste("Error:", conditionMessage(e)), type = "error")
        NULL
      })
    })
  })

  output$mapa <- leaflet::renderLeaflet({
    leaflet::leaflet() |>
      leaflet::addTiles() |>
      leaflet::setView(lng = -58.4173, lat = -34.6118, zoom = 12) # Obelisco, CABA
  })

  # Clic en el mapa: completa origen o destino con las coordenadas del punto
  shiny::observeEvent(input$mapa_click, {
    clic <- input$mapa_click
    texto <- sprintf("%.6f, %.6f", clic$lat, clic$lng)
    if (identical(input$clic_mapa, "origen")) {
      shiny::updateTextInput(session, "direccion_origen", value = texto)
    } else if (identical(input$clic_mapa, "destino")) {
      shiny::updateTextInput(session, "direccion_destino", value = texto)
    }
  })

  # Cada búsqueda nueva empieza con la ruta más rápida seleccionada
  shiny::observeEvent(resultado(), {
    res <- resultado()
    seleccion(if (identical(res$tipo, "transporte")) res$elegidas$idx[1] else NULL)
  })

  shiny::observeEvent(input$ruta_sel, {
    seleccion(as.integer(input$ruta_sel))
  })

  # Mapa: riesgo, origen, destino y las rutas (la seleccionada resaltada)
  shiny::observe({
    res <- resultado()
    shiny::req(res)

    mapa <- leaflet::leafletProxy("mapa") |>
      leaflet::clearShapes() |>
      leaflet::clearMarkers() |>
      leaflet::clearControls() |>
      leaflet::addPolygons(
        data = grilla_riesgo_geo,
        fillColor = ~leaflet::colorNumeric("YlOrRd", riesgo)(riesgo),
        fillOpacity = 0.35, stroke = FALSE, group = "Riesgo"
      ) |>
      leaflet::addMarkers(lng = res$origen$lon, lat = res$origen$lat, label = "Origen") |>
      leaflet::addMarkers(lng = res$destino$lon, lat = res$destino$lat, label = "Destino")

    if (identical(res$tipo, "transporte")) {
      dibujar_transporte(mapa, res, seleccion())
    } else {
      dibujar_auto(mapa, res)
    }
  })

  output$tabla_resultado <- shiny::renderUI({
    res <- resultado()
    shiny::req(res)

    if (identical(res$tipo, "transporte")) tabla_transporte(res, seleccion()) else tabla_auto(res)
  })
}

shiny::shinyApp(ui, server)
