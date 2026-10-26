# ============================================================
# app.R
# Prototipo Beta - Optimizador de rutas urbanas en CABA con
# prevención de exposición al riesgo delictivo histórico.
#
# Ejecutar con: shiny::runApp("R")
# (o abrir este archivo en RStudio y presionar "Run App")
# ============================================================

source("00_config.R")
source("01_preparar_riesgo.R")
source("funciones_core.R")
source("02_simulacion_resultados.R")  # provee construir_set_prueba_geocodificacion()
source("transporte.R")                # colectivos con riesgo: frontera Pareto (modo "Colectivo")

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

#' Colores de las opciones de colectivo en el mapa (una capa por opción).
COLORES_OPCIONES <- c("#2ecc71", "#3388ff", "#e67e22", "#9b59b6", "#e74c3c", "#16a085", "#7f8c8d")

#' Calcula la frontera de colectivo para dos textos de dirección.
calcular_transporte_app <- function(texto_origen, texto_destino, franja) {
  o <- geocodificar_direccion(texto_origen)
  d <- geocodificar_direccion(texto_destino)
  if (is.null(o)) stop("No se pudo ubicar el origen dentro de AMBA.")
  if (is.null(d)) stop("No se pudo ubicar el destino dentro de AMBA.")
  frontera <- frontera_pareto_transporte(list(lat = o$lat, lon = o$lon),
                                         list(lat = d$lat, lon = d$lon), franja = franja)
  list(tipo = "transporte", origen = o, destino = d, frontera = frontera, franja = franja)
}

#' Dibuja en el mapa las opciones de la frontera: una capa por opción.
dibujar_transporte <- function(mapa, res) {
  opciones <- res$frontera$opciones
  for (i in seq_len(nrow(opciones))) {
    pts <- res$frontera$rutas[[i]]$puntos
    pts <- pts[!is.na(pts$lat), ]
    color <- COLORES_OPCIONES[((i - 1) %% length(COLORES_OPCIONES)) + 1]
    grupo <- sprintf("Opción %d", i)
    etiqueta <- sprintf("%s: %s, exposición %.1f", grupo, formatear_duracion(opciones$duracion_min[i]),
                        opciones$exposicion[i])
    mapa <- leaflet::addPolylines(mapa, lng = pts$lon, lat = pts$lat, color = color, weight = 5,
                                  opacity = 0.85, label = etiqueta, group = grupo)
  }
  grupos <- sprintf("Opción %d", seq_len(nrow(opciones)))
  mapa |>
    leaflet::addLayersControl(
      overlayGroups = c("Riesgo", grupos),
      options = leaflet::layersControlOptions(collapsed = FALSE)
    )
}

#' Panel de resultados para el modo colectivo: una lista por opción, con sus tramos.
tabla_transporte <- function(res) {
  op <- res$frontera$opciones
  bloques <- lapply(seq_len(nrow(op)), function(i) {
    r <- res$frontera$rutas[[i]]
    tramos <- r$tramos
    filas_tramos <- lapply(seq_len(nrow(tramos)), function(k) {
      t <- tramos[k, ]
      texto <- if (t$tipo == "colectivo") {
        sprintf("Línea %s: %s → %s (%d paradas, %s)", t$linea, t$desde, t$hasta, t$paradas,
                formatear_duracion(t$minutos))
      } else {
        sprintf("%s: %s → %s (%s)", t$tipo, t$desde, t$hasta, formatear_duracion(t$minutos))
      }
      shiny::tags$li(texto)
    })
    shiny::tags$div(
      shiny::tags$strong(sprintf("Opción %d", i)),
      sprintf(": %s, %d transbordo(s), exposición %.1f, caminata %.0f min.",
              formatear_duracion(op$duracion_min[i]), op$transbordos[i], op$exposicion[i], op$caminata_min[i]),
      shiny::tags$ul(filas_tramos)
    )
  })
  shiny::tagList(
    shiny::h4("Opciones de colectivo"),
    shiny::tags$p(shiny::em("Horarios programados (GTFS, fecha de referencia del feed). No son tiempo real.")),
    shiny::tags$p(sprintf("Franja: %s. Las opciones son las no dominadas entre tiempo y exposición.",
                          res$franja)),
    bloques
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
ui <- shiny::fluidPage(
  shiny::titlePanel("Optimizador de rutas CABA — Prevención de exposición delictiva (Beta)"),
  shiny::sidebarLayout(
    shiny::sidebarPanel(
      shiny::textInput("direccion_origen", "Dirección de origen",
                        placeholder = "Ej: Mercedes 1846 Llavallol, o Mercedes y Ucrania"),
      shiny::textInput("direccion_destino", "Dirección de destino",
                        placeholder = "Ej: Mercedes 1846 entre Ucrania y Hernandez"),
      shiny::helpText("También podés pegar un link de Google Maps o coordenadas (lat, lon)."),
      shiny::radioButtons("clic_mapa", "Un clic en el mapa define:",
                          choices = c("Nada" = "no", "Origen" = "origen", "Destino" = "destino"),
                          selected = "no", inline = TRUE),
      shiny::radioButtons("modo", "Medio de transporte",
                          choices = c("Auto" = "auto", "A pie" = "caminando",
                                      "Colectivo (con riesgo)" = "transporte"),
                          selected = "auto", inline = TRUE),
      shiny::conditionalPanel(
        condition = "input.modo == 'transporte'",
        shiny::selectInput("franja", "Franja horaria (horarios programados)",
                           choices = c("Mañana (6 a 12)" = "Manana", "Tarde (12 a 20)" = "Tarde",
                                       "Noche (20 a 6)" = "Noche"),
                           selected = franja_actual())
      ),
      shiny::actionButton("calcular", "Calcular ruta óptima", class = "btn-primary"),
      shiny::hr(),
      shiny::helpText("El sistema compara la ruta más rápida contra alternativas",
                       "que evitan las zonas de mayor densidad delictiva histórica",
                       "(2016-2025, sin 2020-2021),",
                       paste0("según el índice de exposición calculado sobre una grilla de ",
                              TAMANO_GRILLA, " m.")),
      shiny::uiOutput("tabla_resultado")
    ),
    shiny::mainPanel(
      leaflet::leafletOutput("mapa", height = "650px")
    )
  )
)

# ============================================================
# SERVER
# ============================================================
server <- function(input, output, session) {

  resultado <- shiny::eventReactive(input$calcular, {
    shiny::req(input$direccion_origen, input$direccion_destino)

    shiny::withProgress(message = "Calculando ruta óptima...", {
      tryCatch({
        if (identical(input$modo, "transporte")) {
          calcular_transporte_app(input$direccion_origen, input$direccion_destino,
                                  franja = input$franja %||% franja_actual())
        } else {
          calcular_ruta_optima(
            input$direccion_origen,
            input$direccion_destino,
            grilla_riesgo_global,
            modo = input$modo
          )
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

  shiny::observeEvent(resultado(), {
    res <- resultado()
    shiny::req(res)

    if (identical(res$tipo, "transporte")) {
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
      dibujar_transporte(mapa, res)
      return(invisible(NULL))
    }

    mapa <- leaflet::leafletProxy("mapa") |>
      leaflet::clearShapes() |>
      leaflet::clearMarkers() |>
      leaflet::addPolygons(
        data = grilla_riesgo_geo,
        fillColor = ~leaflet::colorNumeric("YlOrRd", riesgo)(riesgo),
        fillOpacity = 0.35, stroke = FALSE, group = "Riesgo"
      ) |>
      leaflet::addPolylines(
        data = res$ruta_directa, color = "#3388ff", weight = 5, opacity = 0.9,
        label = "Ruta más rápida", group = "Ruta directa"
      ) |>
      leaflet::addPolylines(
        data = res$ruta_optima, color = "#2ecc71", weight = 5, opacity = 0.9,
        label = "Ruta óptima (riesgo reducido)", group = "Ruta óptima"
      ) |>
      leaflet::addMarkers(lng = res$origen$lon, lat = res$origen$lat, label = "Origen") |>
      leaflet::addMarkers(lng = res$destino$lon, lat = res$destino$lat, label = "Destino") |>
      leaflet::addLayersControl(
        overlayGroups = c("Riesgo", "Ruta directa", "Ruta óptima"),
        options = leaflet::layersControlOptions(collapsed = FALSE)
      )
    mapa
  })

  output$tabla_resultado <- shiny::renderUI({
    res <- resultado()
    shiny::req(res)

    if (identical(res$tipo, "transporte")) return(tabla_transporte(res))

    m <- res$tabla_metricas[res$idx_optima, ]
    base <- res$tabla_metricas[1, ]
    eficiencia_e <- ALPHA_TIEMPO * res$A_eficacia + BETA_RIESGO * res$B_tiempo_respuesta +
      GAMMA_EFICIENCIA * VALOR_C_GLOBAL

    shiny::tagList(
      shiny::h4("Puntos normalizados"),
      shiny::tags$ul(
        shiny::tags$li(sprintf("Origen: %s (%s)", res$origen$direccion, res$origen$fuente %||% "")),
        shiny::tags$li(sprintf("Destino: %s (%s)", res$destino$direccion, res$destino$fuente %||% ""))
      ),
      shiny::h4("Ruta óptima seleccionada"),
      shiny::tags$p(shiny::em("Resultado del problema resuelto (no son variables de evaluación):")),
      shiny::tags$ul(
        shiny::tags$li(sprintf("Tiempo de viaje: %s (ruta más rápida: %s)",
                               formatear_duracion(m$duracion_min), formatear_duracion(base$duracion_min))),
        shiny::tags$li(sprintf("Exposición al riesgo: %.1f (ruta más rápida: %.1f)", m$riesgo_abs, base$riesgo_abs))
      ),
      shiny::tags$p(shiny::em("Variables de evaluación del prototipo:")),
      shiny::tags$ul(
        shiny::tags$li(sprintf("A (Eficacia): %.2f", res$A_eficacia)),
        shiny::tags$li(sprintf("B (Tiempo de respuesta): %.2f  (%.1f s reales)", res$B_tiempo_respuesta, res$tiempo_respuesta_seg)),
        shiny::tags$li(sprintf("C (Robustez de geocodificación): %.2f", VALOR_C_GLOBAL)),
        shiny::tags$li(shiny::strong(sprintf("E (Eficiencia global): %.2f", eficiencia_e)))
      )
    )
  })
}

shiny::shinyApp(ui, server)
