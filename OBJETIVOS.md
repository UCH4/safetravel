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
| Base de datos de transporte | ⚠️ | `data/transporte.sqlite` (18,8 MB), solo colectivos, tres tablas: `paradas_riesgo` (43.557), `lineas_recorridos` (1.047), `conectividad` (135.987 tramos). Horarios del 1-oct-2019 (vencidos). Verificada: sin huérfanos, sin tramos de más de 30 min. |
| Ruteo sesgado en colectivos | ⚠️ | `calcular_colectivo_seguro()` en `R/transporte.R`, con Dijkstra sobre un grafo de estados (línea, parada). Funciona para CABA; probado en pares de puntos (ver abajo). No está conectado a la app. |
| Evaluación del ruteo sesgado | ⚠️ | `R/04_evaluacion_transporte.R`. Resultados modestos (ver sección 8). |
| Planificador multimodal (OTP) | ❌ | Grafo construido (`data/otp/graph/graph.obj`, 987 MB). El servidor no se levantó ni se probó. |
| Integración de transporte en la app | ❌ | Ninguna de las dos rutas de transporte está conectada a la interfaz. |

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
- [ ] Mostrar en la app un aviso cuando se usa la grilla sintética o la dirección cae fuera de CABA (13, 17).

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

---

## 8. Ruteo sesgado por riesgo en colectivos: evaluación

Se corrió `R/04_evaluacion_transporte.R` sobre 50 pares de puntos dentro de CABA (centroides de la grilla separados entre 2 y 8 km), franja Tarde, con `factor_sesgo = 0` (ruta más rápida) y `factor_sesgo = 1` (ruta sesgada). De los 50 pares, 46 tuvieron recorrido en colectivo.

| Métrica | Resultado |
|---|---|
| Pares con el mismo recorrido | 30 de 46 |
| Pares con reducción de exposición ≥ 10 % | 9 de 46 |
| Mediana de reducción de exposición | 0 % (IQR 0 a 0 %) |
| Mediana de aumento de tiempo | 0 % (IQR 0 a 0,5 %) |
| Wilcoxon pareado (exposición sesgada < rápida) | V = 141, p = 0,012 |
| Transbordos medios (rápida / sesgada) | 0,59 / 0,61 |

**Lectura.** El sesgo cambia el recorrido en 16 de 46 pares. Cuando lo cambia, reduce la exposición con un costo de tiempo bajo. El efecto es estadísticamente significativo en el conjunto (p = 0,012), pero es chico: la mediana es 0. Hay que decirlo así en el informe.

**Por qué el efecto es chico.**
- Solo 8.571 de 43.557 paradas están dentro de la grilla (CABA). Las demás tienen riesgo cero, así que el algoritmo no tiene por dónde desviarse.
- Dentro de CABA, la grilla de 500 m es gruesa: muchas paradas de un mismo tramo caen en la misma celda.
- La red de colectivos da pocas alternativas reales entre dos puntos. Muchas veces el recorrido más rápido ya es el menos riesgoso.

## 9. Problemas nuevos y decisiones de diseño

- **Tramos de más de 30 min entre paradas consecutivas** (212 en la primera versión, máximo 112 min): errores del origen. Se descartan en el ETL. La evaluación no cambió con este filtro.
- **Transbordos a pie encadenados.** En algunos recorridos el algoritmo camina entre dos o tres paradas cercanas para subir a una línea que pasa por otra. Es correcto según el modelo, pero no es lo que haría una persona. Podría limitarse a un transbordo a pie por trayecto.
- **Tiempo de consulta.** Construir el grafo tarda unos 20 s (181.600 estados, 610.972 aristas). Cada consulta tarda entre 4 y 5 s con 3 alternativas.
- **Esperas por franja.** La espera de la franja Noche es grande (promedio 69 min en la base) porque hay pocos servicios. Es real en los datos de 2019, pero el valor no debería usarse para decidir sin verificarlo con horarios vigentes.
- **Prueba sobre distancias chicas.** Los pares son de 2 a 8 km dentro de CABA. No se evaluó el comportamiento con origen o destino fuera de la grilla.
- **Dos pendientes para la siguiente versión:** conectar `calcular_colectivo_seguro()` a la interfaz, y definir una métrica de exposición por tramo que no dependa solo de la grilla de 500 m (por ejemplo, la densidad de robos por paradas o por calle).
