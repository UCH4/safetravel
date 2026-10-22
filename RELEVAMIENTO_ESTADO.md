# Relevamiento del estado actual: código vs. documentación del TP

Fecha: 2026-10-18. Alcance: `R/`, `data/`, `README.md`, `materiales_y_metodos.md`, y la Introducción del Grupo 3 (`Introducción_Comisión[DF]_Grupo3 (1).md`).

## 1. Qué funciona hoy

| Componente | Estado | Evidencia |
|---|---|---|
| Carga de delitos CABA 2016–2025 (10 CSV) | ✅ | `R/01_preparar_riesgo.R`, `cargar_delitos_caba()`; 1.387.622 registros |
| Filtro robos + hurtos, sin 2020–2021 | ✅ | `TIPOS_DELITO_RIESGO`, `ANIOS_EXCLUIDOS` en `R/00_config.R` |
| Asignación a barrios (GeoJSON, 48 barrios) | ✅ | `filtrar_delitos_riesgo()`; polígonos reparados con `st_make_valid()` |
| Grilla de riesgo real (500 m, 906 celdas) | ✅ | `data/grilla_riesgo.rds`, con parámetros en `attr(, "parametros")` |
| Partición cronológica 2016–19 + 2022–23 / 2024 ajuste / 2025 prueba | ✅ | `ajustar_parametros_grilla()`, `construir_grilla_riesgo_real()` |
| App Shiny: origen → destino → mapa + A, B, C, E | ✅ | Probada: HTTP 200 con grilla real |
| Geocodificación (Nominatim vía `tidygeocoder`) | ✅ | `geocodificar_direccion()` |
| Ruta en auto (OSRM público, perfil driving) | ✅ | `obtener_ruta()` |
| Selección de ruta óptima (entre candidatas, tope de +25 % de tiempo) | ✅ | `seleccionar_mejor_candidata()` |
| Simulación de 100 trayectos | ⚠️ Funciona, pero **con resultados viejos** | `data/resultados_simulacion.csv` es de la grilla sintética (13:02) |

## 2. Qué falta en el código

### Funcionalidad (lo que pediste para la beta)
- **Caminar**: no existe. El perfil `foot` del OSRM público devuelve lo mismo que `driving` (verificado), así que no sirve.
- **Transporte público** (colectivo, subte, tren, con líneas, cuadras, horarios): no existe. Los datos de colectivos y subte de CABA están vencidos (2019) o suspendidos; el único vigente es trenes. Google requiere tarjeta; Transitous no cubre Buenos Aires (verificado: 0 itinerarios); geOps no confirmó cobertura.
- **Selector de modo** (auto / caminando / transporte): no existe en la UI.
- **Google Routes**: la rama `obtener_ruta_google()` usa la **Directions API** (legacy), no Routes API, y no soporta modos ni transporte público.

### Calidad del ruteo
- **Desvío sin efecto**: en el caso de la captura, A = 0.00 (la ruta óptima es la directa). `proponer_waypoints_desvio()` suma +0,0027° al centroide sin orientar hacia celdas de menor riesgo (`R/funciones_core.R`, línea 99).
- **Selección**: `seleccionar_mejor_candidata()` elige la de menor riesgo dentro del +25 % de tiempo. El documento dice que se elige la que maximiza E. Son criterios distintos.

### Estadística y evaluación
- **Prueba t** en `R/02_simulacion_resultados.R` (línea 83): con 6 de 100 trayectos cambiados, la diferencia está muy sesgada. Cambiar a Wilcoxon pareado.
- **Muestreo uniforme** de origen-destino (`generar_puntos_aleatorios`). El documento dice ponderado por población; `data/raw/poblacion_barrios.csv` ya está disponible.
- **Simulación no rehecha** con la grilla real.
- **Set de prueba de C**: 6 direcciones placeholder (`construir_set_prueba_geocodificacion()`); el documento pide 50.
- **Tiempos por resolución** (100/250/500 m): no medidos.
- **Ponderación horaria**: solo nocturna, y el ajuste no la justifica (peso 1,0 / 1,5 / 2,0 dan el mismo Spearman).
- **Ponderación por día de la semana**: no implementada.

### Limpieza
- `R/02_simulacion_resultados.R:75`: `incProgress <- NULL` no hace nada.
- `googlePolylines` y `httr` se usan en la rama Google, pero no están en `paquetes_requeridos`.
- `purrr` está en los paquetes requeridos y no se usa.
- Si la grilla real falla, la app cae en la sintética y solo lo dice en consola.

## 3. Textos que no coinciden con el código

| Lugar | Dice | Código real |
|---|---|---|
| `R/app.R` línea 46 (texto de la app) | "grilla de **250 m**" | La grilla es de **500 m** |
| `README.md` línea 23 | `data/delitos_2016_2025.csv` (un solo archivo) | Son 10 archivos anuales en `data/raw/` |
| `README.md` línea 40 | Google Routes API | Usa Directions API (legacy) |
| `materiales_y_metodos.md` línea 13 | Grilla de **250 m** | Grilla de **500 m** (ajuste 2024) |
| `materiales_y_metodos.md` línea 13 | Ponderada por franja **y día de la semana** | Solo franja nocturna; ajuste sin efecto; día no implementado |
| `materiales_y_metodos.md` línea 51 | Medido con celdas de 100, 250 y 500 m | No medido |
| `materiales_y_metodos.md` línea 61 | Set de prueba de **50** direcciones | Hay **6** |
| `materiales_y_metodos.md` línea 75 | Pares ponderados por densidad poblacional | Uniforme |
| `materiales_y_metodos.md` línea 75 | Prueba t de Student | Ver sección 2 (cambiar a Wilcoxon) |

## 4. Diferencias entre la Introducción del TP y el código

### 4.1 Definiciones de A, B y C (contradicción dentro de la propia Introducción)

| | Introducción, párrafo de diseño (línea 69) | Introducción, secciones 4–6 | Introducción, sección 8 | `materiales_y_metodos.md` | Código |
|---|---|---|---|---|---|
| **A** | Tiempo de respuesta y duración normalizada | **Eficacia** (reducción de riesgo) | (no define) | Eficacia | Eficacia |
| **B** | Precisión en la evaluación del riesgo | **Tiempo de respuesta** min(1, 5/t) | "exposición al riesgo (B)" | Tiempo de respuesta | Tiempo de respuesta |
| **C** | Eficiencia computacional y cobertura | **Robustez de geocodificación** | (no define) | Robustez de geocodificación | Robustez de geocodificación |

**Conclusión**: la Introducción se contradice a sí misma. Las secciones 4 a 6 y `materiales_y_metodos.md` coinciden con el código. El párrafo de la línea 69 y la sección 8 no. Hay que corregir el párrafo de la línea 69 y la frase de la sección 8.

### 4.2 Otras diferencias

- **Selección de la ruta óptima**: la Introducción (sección 3, paso 4) dice que se elige la que **maximiza E**. El código elige la de menor riesgo dentro del +25 % de tiempo.
- **Ponderación horaria y diaria** (sección 2): la Introducción dice franja horaria **y** día de la semana. Solo se implementa la franja nocturna, y no mejora el ajuste.
- **Motor de ruteo**: la sección 3 dice OSRM; la sección 1 y `materiales_y_metodos.md` mencionan Google Routes API como alternativa. El código usa Directions API, no Routes API.
- **Muestreo** (sección 8): ponderado por densidad poblacional; el código es uniforme.
- **Prueba** (sección 8): t de Student pareada; con esta distribución no es apropiada.
- **Set de prueba de C** (sección 6): 50 direcciones; hay 6.
- **Medición de B por resolución** (sección 5): 100/250/500 m; no hecha.
- **Grilla** (sección 2): 250 m en los textos; la grilla real es de 500 m.
- **Transporte público**: no aparece en la Introducción ni en `materiales_y_metodos.md`. Si se implementa, hay que agregarlo al diseño y a los métodos.
- **Fechas y encabezados**: la entrega figura como 03/09/26 (ya vencida) y hay un typo "06/010/2026".
- **Referencias**: el enlace al informe 2025 del Mapa del Delito no fue verificado.

## 5. Prioridad sugerida

1. **Decidir A, B, C** y corregir la Introducción (línea 69 y sección 8) y `materiales_y_metodos.md`. Sin esto, el documento no es entregable.
2. **Corregir textos** de la app (250 → 500 m) y del README (archivos anuales, Routes API).
3. **Rehacer la simulación** con la grilla real, con Wilcoxon y muestreo ponderado por población.
4. **Decidir el criterio de selección** de la ruta óptima (min riesgo con tope de tiempo, o maximizar E) y alinear el documento.
5. **Decidir el modo de transporte**: auto y caminata primero, transporte público cuando haya datos vigentes o una clave de geOps.
6. **Mejorar el desvío** para que A deje de ser 0 en casos como el de la captura.
7. **Set de 50 direcciones** para C.
