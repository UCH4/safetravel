# Objetivos, estado actual y problemas abiertos

Proyecto: **Optimizador de rutas CABA con prevención de exposición delictiva** (TP3, Metodología del Aprendizaje, ITBA, Grupo 3).
Última actualización del estado: **22/10/2026**.

Este documento describe lo que el prototipo hace hoy, lo que no hace, y los errores y decisiones pendientes. Es la referencia para retomar el trabajo.

---

## 1. Objetivos

**Objetivo general.** Construir un prototipo web en R (Shiny + Leaflet) que, dado un origen y un destino en CABA, compare la ruta más rápida con una alternativa que reduzca la exposición a robos y hurtos históricos, sin costo y sin depender de tarjeta de crédito.

**Objetivos específicos**

1. **Mapa de riesgo real:** grilla de 500 m sobre los robos y hurtos de CABA 2016–2025 (sin 2020–2021).
2. **Comparativa de rutas:** ruta directa vs. ruta óptima, con las variables A (eficacia), B (tiempo de respuesta), C (robustez de geocodificación) y E (eficiencia global).
3. **Multimodal:** auto, a pie y transporte público (colectivo, subte, tren), con líneas, paradas, trasbordos y espera.
4. **Entrada flexible de direcciones:** lenguaje natural, cruces ("entre … y …"), coordenadas, clic en el mapa y links de Google Maps.
5. **Autonomía:** que la app funcione sin claves pagas ni tarjeta. Las fuentes deben ser gratuitas y oficiales cuando sea posible.
6. **Entregable académico:** introducción y materiales y métodos consistentes con el código (ver sección 5).

---

## 2. Estado actual por componente

| Componente | Estado | Detalle |
|---|---|---|
| Grilla de riesgo real | ✅ | 500 m, 906 celdas, `data/grilla_riesgo.rds`. Ajuste con 2024, prueba con 2025 (Spearman 0,954). |
| Ruteo en auto | ⚠️ | OSRM público de demostración (`router.project-osrm.org`). Sin tráfico en vivo; sin garantía de disponibilidad. |
| Ruteo a pie | ✅ | OSRM peatonal local en Docker (puerto 5001); respaldo en Mapbox si está el token. |
| Geocodificación | ✅ | Nuevo módulo `R/geocodificacion.R`: coordenadas, link de Google Maps, USIG (GCBA), Georef (IGN) y Nominatim como último recurso. Probado con 6 casos. |
| Desambiguación de cruces | ⚠️ | "Mercedes 1846 entre Ucrania y Hernandez" resuelve a Llavallol usando la intersección. Heurística; probada con pocos casos. |
| Clic en el mapa | ⚠️ | Implementado (selector "Origen / Destino"). Falta probarlo en la app abierta. |
| Formato de duración | ✅ | "1 h 12 min" en lugar de "72.4 min". Verificado con valores de prueba; falta verlo en la app. |
| Variables A, B, C, E | ⚠️ | Calculadas, pero el criterio de selección y el desvío tienen problemas (sección 4). |
| Simulación de 100 trayectos | ❌ | `data/resultados_simulacion.csv` es de la grilla sintética. Hay que volver a correrla. |
| Base de datos de transporte | ⚠️ | `data/transporte.sqlite` (35 MB) con colectivos, subte y trenes. Datos vencidos (ver sección 4). |
| Planificador de transporte (OTP) | ❌ | Grafo construido (`data/otp/graph/graph.obj`, 987 MB). El servidor no se levantó ni se probó. |
| Integración de transporte en la app | ❌ | `R/transporte.R` está escrito pero no probado y no está conectado a la interfaz. |

Leyenda: ✅ funciona y se probó · ⚠️ funciona con limitaciones o sin probar del todo · ❌ no funciona o no está hecho.

---

## 3. Fuentes de datos

| Dato | Fuente | Vigencia | Uso |
|---|---|---|---|
| Robos y hurtos | Buenos Aires Data (delitos, 2016–2025) | 2016–2025, sin 2020–2021 | Grilla de riesgo |
| Límites barriales | Buenos Aires Data (GeoJSON) | Actual | Recorte de la grilla |
| Población por barrio | `data/raw/poblacion_barrios.csv` | Censo | Muestreo ponderado (pendiente) |
| Calles y ruteo | OpenStreetMap (`argentina-latest.osm.pbf`) | Actual, colaborativa | OSRM y OTP |
| Geocodificación | USIG (GCBA), Georef (IGN), Nominatim | Actual | Normalización de direcciones |
| Colectivos (horarios) | GTFS de BA Data, feed de 2019 | **Vencido**: calendario sep–dic 2019 | Paradas y horarios programados |
| Subte (horarios) | GTFS de SBASE | **Vencido**: calendario 2014–2021 | Horarios programados |
| Trenes (horarios) | GTFS de Trenes Argentinos (BA Data) | **Vencido**: feb–abr 2020 | Horarios programados |
| API de Transporte CABA | `datosabiertos-transporte-apis.buenosaires.gob.ar` | Requiere credenciales | Subte en vivo (pendiente) |

Ver la especificación completa de la API en `https://datosabiertos-apis.buenosaires.gob.ar/swagger/spec/Transporte_3.json`.

---

## 4. Errores y problemas abiertos

### 4.1 Seguridad (urgente)

1. **Tokens pegados en el chat.** Se compartieron un token de Mapbox (`pk.eyJ…`) y uno de LocationIQ (`pk.71c3…`) en la conversación. **Hay que rotarlos** en sus paneles. El de Mapbox está guardado en `~/.Renviron` (fuera del repositorio). El de LocationIQ no se usó ni se guardó.
2. **Credenciales de la API de Transporte.** El registro se hizo, pero el correo con las credenciales no llegó. Hay que reintentar con `apitransporte@buenosaires.gob.ar`. Las credenciales nunca van al código ni al chat.

### 4.2 Datos de transporte

3. **Ningún GTFS de transporte público de AMBA está vigente.** Colectivos (2019), subte (2014–2021) y trenes (2020) están vencidos. Las fichas de BA Data dicen "suspendido y en revisión".
4. **No hay fecha común a los tres modos.** Colectivos tiene servicio solo en sep–dic 2019, y trenes solo en feb–abr 2020. Por eso la base usa una fecha de referencia por modo y **no se puede planificar un viaje multimodal en un mismo día**.
5. **Colectivos en tiempo real no están disponibles.** La API de Transporte documenta `colectivos/vehiclePositionsSimple`, pero el servidor responde 404 ("No listener for endpoint"). Trenes en tiempo real también responde 404.
6. **Subte en tiempo real.** Los endpoints existen (`subtes/forecastGTFS`, etc.) y responden 401, así que requieren credenciales que todavía no se tienen.
7. **Feed reducido de colectivos.** Para que OTP pudiera construir el grafo, se armó `data/otp/graph/colectivos-gtfs-2019-10-01.zip` con solo los viajes del 1-oct-2019 (9,7 millones de horarios). El feed completo (31 millones) agotaba la memoria.

### 4.3 Planificador de transporte (OTP)

8. **Versión de Java.** OTP 2.10 requiere Java 25; la Mac tiene Java 21. Se usa **OTP 2.6.0** (compilado para Java 21).
9. **Memoria.** La construcción del grafo necesita `-Xmx16g`. Con 8 GB falla con `OutOfMemoryError`.
10. **Período de servicio.** Por defecto OTP limita los servicios a los últimos 4 años y descarta todo el calendario de 2019. Se fijó `transitServiceStart` = 2019-09-01 y `transitServiceEnd` = 2020-03-01 en `data/otp/graph/build-config.json`.
11. **No probado.** El servidor no se levantó, no se verificó ningún itinerario y los nombres de parámetros (`transferPenalty`, `walkReluctance`) no están confirmados contra esta versión.
12. **Espacio en disco.** La carpeta de datos ocupa unos 5 GB (OSRM 3,8 GB, OTP 1,2 GB). Durante las pruebas el disco llegó a tener 15 GB libres.

### 4.4 Ruteo y riesgo

13. **Solo CABA tiene riesgo.** Las direcciones fuera de CABA (por ejemplo Llavallol) reciben riesgo cero porque la grilla no las cubre. Hay que avisarlo en la app.
14. **Tiempos de auto sin tráfico.** El OSRM público calcula con velocidades de flujo libre.
15. **Desvío sin orientación.** `proponer_waypoints_desvio()` suma +0,0027° al centroide sin mirar hacia celdas de menor riesgo. Por eso A queda en 0 en muchos casos.
16. **Criterio de selección distinto del documento.** El código elige la ruta de menor riesgo dentro de +25 % de tiempo. El documento dice que se elige la que maximiza E.
17. **Grilla sintética silenciosa.** Si falla la carga de la grilla real, la app cae a la sintética y solo lo dice en consola.

### 4.5 Evaluación y documento

18. **Simulación desactualizada.** Los resultados de 100 trayectos son de la grilla sintética. Hay que volver a correr `R/02_simulacion_resultados.R`.
19. **Prueba estadística.** Con 6 de 100 trayectos cambiados, la t de Student pareada no es adecuada. Se propone Wilcoxon pareado.
20. **Muestreo.** Los pares origen–destino son uniformes en el bounding box. El documento dice ponderados por población.
21. **Set de prueba de C.** Hay 6 direcciones placeholder; el documento pide 50 verificadas a mano.
22. **Contradicción en la Introducción.** El párrafo de diseño (línea 69) define A como tiempo, B como riesgo y C como eficiencia. Las secciones 4–6 y `materiales_y_metodos.md` definen A como eficacia, B como tiempo y C como robustez de geocodificación. El código sigue la segunda versión.
23. **Textos desactualizados.** `materiales_y_metodos.md` menciona grilla de 250 m (es de 500 m) y ponderación por día de la semana (no implementada). Ver `RELEVAMIENTO_ESTADO.md`, sección 3.
24. **Fecha de entrega vencida.** El documento dice 03/09/26.

### 4.6 Código

25. **Rama de Google obsoleta.** `obtener_ruta_google()` usa la Directions API (legacy), no la Routes API, y no soporta transporte público.
26. **Dependencias.** `httr` y `googlePolylines` se usan en la rama de Google pero no están en `paquetes_requeridos`. `purrr` está y no se usa.
27. **Código muerto.** `R/02_simulacion_resultados.R` tiene `incProgress <- NULL`, que no hace nada.
28. **Sin pruebas automáticas.** No hay tests. Las funciones de geocodificación se probaron a mano.
29. **Recarga de la app.** Shiny no recarga las funciones al cambiar el código; hay que reiniciar `shiny::runApp("R")`.

---

## 5. Próximos pasos (en orden)

1. **Rotar los tokens** expuestos en el chat (sección 4.1).
2. **Levantar OTP y probar un viaje** de punta a punta. Si funciona, conectar `R/transporte.R` a la interfaz con las opciones: más rápido, menos trasbordos, menos caminata, trazados alternativos, y el punto de espera con la frecuencia de la base.
3. **Decidir y etiquetar los horarios.** Cada itinerario debe mostrar "programado, fecha X" y no "en tiempo real".
4. **Arreglar el desvío** (punto 15) y decidir el criterio de selección (punto 16).
5. **Volver a correr la simulación** con la grilla real, con Wilcoxon y muestreo ponderado.
6. **Ampliar el set de C** a 50 direcciones verificadas.
7. **Corregir la Introducción y `materiales_y_metodos.md`** según las secciones 4.5 y 3 de `RELEVAMIENTO_ESTADO.md`.
8. **Pedir a la Ciudad o a SUBE** los GTFS vigentes de colectivos y subte, y el acceso a colectivos en tiempo real.

---

## 6. Documentos relacionados

- `README.md`: cómo instalar y correr el prototipo.
- `GUIA_BETA.md`: guía de uso de la beta (pendiente de actualizar con transporte y Docker).
- `TODO.md`: lista de pendientes de código y documento.
- `RELEVAMIENTO_ESTADO.md`: comparación detallada entre código y documento.
- `ANALISIS_INTRODUCCION_vs_IMPLEMENTACION.md` e `INVESTIGACION_DATOS_Y_MEJORAS.md`: análisis previos.
- `materiales_y_metodos.md`: texto de la sección de métodos (desactualizado, ver punto 23).

---

## 7. Lista para terminar el prototipo y mejorarlo

### 7.1 Imprescindible para la entrega

- [ ] Rotar los tokens de Mapbox y LocationIQ expuestos en el chat (4.1).
- [ ] Probar la app de punta a punta en el navegador: origen y destino por texto, por cruce, por coordenadas, por link de Google Maps y por clic en el mapa.
- [ ] Volver a correr `R/02_simulacion_resultados.R` con la grilla real (18).
- [ ] Cambiar la prueba t por Wilcoxon pareado y reportar también el efecto solo en los trayectos que cambiaron (19).
- [ ] Corregir la definición de A, B y C en el párrafo de diseño de la Introducción (22).
- [ ] Corregir `materiales_y_metodos.md`: grilla de 500 m, sin ponderación por día, set de C, prueba estadística (23).
- [ ] Decidir el criterio de selección (min riesgo con tope de tiempo, o maximizar E) y alinear código y documento (16).
- [ ] Mostrar en la app un aviso cuando se usa la grilla sintética o la direccion cae fuera de CABA (13, 17).

### 7.2 Ruteo y riesgo

- [ ] Reescribir `proponer_waypoints_desvio()` para que el desvío se oriente hacia celdas de menor riesgo (15).
- [ ] Muestreo ponderado por población para los pares origen–destino (20).
- [ ] Ampliar el set de C a 50 direcciones verificadas a mano (21). Recalcular C con el nuevo geocodificador.
- [ ] Evaluar normalización por percentil del riesgo, porque la mediana es 0,08 (TODO.md).
- [ ] Mejorar la desambiguación de cruces con más casos de prueba (desambiguación en `R/geocodificacion.R`).

### 7.3 Transporte público

- [ ] Levantar OTP 2.6.0 sobre `data/otp/graph` y probar un viaje de punta a punta (8–11).
- [ ] Confirmar los parámetros de preferencia (`transferPenalty`, `walkReluctance`, `maxWalkDistance`) con esta versión.
- [ ] Conectar `R/transporte.R` a la interfaz: opciones "más rápido", "menos trasbordos", "menos caminata", "trazados alternativos", y el punto de espera con la frecuencia de `data/transporte.sqlite`.
- [ ] Mostrar cada tramo con su etiqueta de vigencia ("programado, fecha X").
- [ ] Calcular la exposición al riesgo de cada itinerario con `calcular_riesgo_ruta()` y permitir elegir la opción de menor riesgo.
- [ ] Resolver la falta de fecha común: colectivos (sep–dic 2019) y trenes (feb–abr 2020) no se pueden planificar juntos hoy (4).
- [ ] Conseguir GTFS vigentes de colectivos y subte: pedir a `apitransporte@buenosaires.gob.ar` y a la Ciudad (3).
- [ ] Obtener credenciales de la API de Transporte (correo que no llegó, 4.1) y probar `subtes/forecastGTFS` (6).
- [ ] Decidir si se incluyen cortes de calles y EcoBici en el mapa (endpoints con 401 ya confirmados).

### 7.4 Código y calidad

- [ ] Agregar `httr`, `jsonlite`, `DBI`, `RSQLite` y `data.table` a `paquetes_requeridos`; quitar `purrr` si no se usa (26).
- [ ] Eliminar `incProgress <- NULL` (27).
- [ ] Reemplazar la rama de Google (Directions legacy) por Routes API o quitarla (25).
- [ ] Mostrar el error real en consola en lugar de caer en la grilla sintética en silencio (17).
- [ ] Pruebas automáticas con `testthat` para `calcular_eficacia`, `calcular_tiempo_respuesta`, `peso_franja`, `decodificar_polilinea`, `normalizar_texto` y `generar_consultas`.
- [ ] Documentar en el README cómo reproducir el contenedor OSRM peatonal (ver nota en README).
- [ ] Liberar espacio en disco: `data/osrm/` y `data/otp/` ocupan unos 5 GB (12).

### 7.5 Documentación

- [ ] Actualizar `GUIA_BETA.md` con transporte, Docker y las nuevas formas de entrada de direcciones.
- [ ] Actualizar `TODO.md` y `RELEVAMIENTO_ESTADO.md` con el estado de este documento.
- [ ] Revisar las referencias del documento (el informe 2025 del Mapa del Delito no fue verificado).
- [ ] Corregir fechas y encabezados del documento (la entrega figura como 03/09/26, ya vencida).
