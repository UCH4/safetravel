# Relevamiento: cómo mejorar el ruteo de transporte con riesgo

Fecha: 26/10/2026. Estado: pendiente de confirmación antes de crear la rama `mejora/ruteo-riesgo-transporte`.

## 1. Qué hace hoy el ruteo sesgado

`calcular_colectivo_seguro()` (R/transporte.R) calcula la ruta mínima con costo
`w = (tiempo + espera/2 si sube) × (1 + factor × riesgo)` sobre un grafo de estados (línea, parada).
El riesgo de cada tramo es el promedio de `score_riesgo` de sus dos paradas.

## 2. Barrido de factor (46 pares dentro de CABA, franja Tarde)

Cada fila compara contra la ruta más rápida (factor 0).

| Factor | Pares que cambian de ruta | Reducción mediana de exposición | Pares con reducción ≥ 10 % | Aumento mediano de tiempo | Aumento de tiempo p90 |
|---|---|---|---|---|---|
| 0 (rápida) | 0 | 0 % | 0 | 0 % | 0 % |
| 1 | 16 | 0 % | 9 | 0 % | 3,6 % |
| 3 | 19 | 0 % | 12 | 0 % | 5,1 % |
| 5 | 25 | 0 % | 15 | 0,4 % | 8,8 % |
| 10 | 29 | 7,8 % | 21 | 5,0 % | 29 % |

**Lectura.** El efecto aparece con factores altos. Con factor 1 la mayoría de los pares no cambia. Con factor 10 la mediana de reducción llega a 7,8 %, pero el 10 % de los pares paga más de 29 % de tiempo extra. Ninguna escala da un efecto grande sin costo de tiempo.

## 3. Corrección al diagnóstico anterior

- **Alternativas: no es el problema.** Con k = 5, los 46 pares tienen 5 rutas distintas. Eso descarta la hipótesis de "pocas alternativas". Falta verificar si son realmente distintas en el sentido de tramos compartidos (pendiente).
- **Distribución del riesgo.** Entre las 8.635 paradas de CABA con dato, la mediana es 0,13 y el percentil 90 es 0,35. Solo 334 paradas superan 0,5. La normalización por máximo deja casi todo en el rango bajo, así que un factor 1 mueve el costo poco.
- **Paradas sin dato.** 34.922 de 43.557 paradas están fuera de la grilla y valen 0. Sigue siendo el límite más importante para AMBA.
- **Grilla de 500 m.** Muchas paradas comparten celda. Pendiente medir cuántas paradas por celda hay y cuánto cambia el resultado con 250 m.

## 4. Base teórica

- **Ruteo bicriterio en transporte público.** RAPTOR (Delling, Pajor y Werneck, 2012) calcula el conjunto de Pareto sobre tiempo y transbordos sin Dijkstra, por rondas. McRAPTOR extiende el método a más criterios. Fuente: [Round-Based Public Transit Routing](https://dl.acm.org/doi/10.1287/trsc.2014.0534). Trabajo con viajes (trip-based): [Scalable Algorithms for Bicriterion Trip-Based Transit Routing](https://arxiv.org/pdf/2111.06654).
- **Ruteo seguro con crimen.** SafePaths y Route-The Safe formulan el problema como camino bicriterio distancia–riesgo. Son trabajos sobre calles, no sobre transporte. Fuente: [Route-The Safe](https://www.researchgate.net/publication/338096313_Route-The_Safe_A_Robust_Model_for_Safest_Route_Prediction_Using_Crime_and_Accidental_Data).
- **Trade-off y frontera de Pareto.** Un trabajo de tiempo–seguridad muestra que minimizar una suma ponderada solo encuentra parte de la frontera. Las rutas no soportadas por la suma no aparecen nunca. Fuente: [Tradeoffs between safety and time](https://www.sciencedirect.com/science/article/pii/S0968090X18316309).
- **Hueco.** No encontré trabajos que combinen riesgo delictivo, tiempo y horarios de transporte en un modelo de Pareto. Es un punto a documentar en el TP.

## 5. Herramientas

- **OpenTripPlanner 2.** Tiene `walkReluctance`, `transferPenalty` y `accessEgress.penalty` para ajustar costos. Hay un PR de "walk safety" en el ruteo a pie. No tiene datos de crimen. Fuente: [Router configuration](https://docs.opentripplanner.org/en/v2.3.0/RouterConfiguration/). Sirve como motor de horarios cuando haya GTFS vigente.
- **Nuestro grafo propio.** Es la única forma hoy de meter el riesgo dentro del costo. Se mantiene.

## 6. Andén

Andén no calcula viajes con transbordos. Su modelo de datos es una llegada por servicio (línea, destino, minutos, estado, en vivo o programado). Ver su [contrato de observación](https://github.com/alandaitch/anden/blob/main/schemas/transport-observation.schema.json). Lo que sí sirve de Andén es el etiquetado de cada dato como en vivo o programado.

## 7. Mejoras propuestas, en orden

1. **Frontera Pareto.** Devolver el conjunto no dominado de rutas (tiempo, exposición) en lugar de una sola ruta con un factor. Opción: barrido de factor (1, 3, 5, 10) y filtrado de dominadas, o ε-constraint con tope de tiempo.
2. **Normalización del riesgo.** Por percentil, para que el factor actúe sobre diferencias reales entre paradas. Hoy el percentil 90 es 0,35 y el máximo 1.
3. **Riesgo en tramos a pie y en la espera.** Hoy el costo a pie no tiene riesgo. Las esperas en paradas nocturnas tampoco.
4. **Un transbordo a pie por trayecto como máximo.** Hoy el algoritmo encadena caminatas entre paradas cercanas.
5. **Frecuencias por franja para subte y trenes.** Como los GTFS no comparten fecha, usar frecuencias medias por franja en vez de horarios exactos. Se documenta como "frecuencias programadas".
6. **Evaluación con frontera.** Comparar la curva en los mismos pares, con y sin tope de tiempo. Esto reemplaza la comparación de un solo factor.
7. **Grilla de 250 m** como sensibilidad. Requiere volver a validar el documento.

## 8. Problemas del código a corregir en la rama

- `R/04_evaluacion_transporte.R` descarta pares que fallan en vez de muestrear otro: la muestra baja de 50 a 46.
- `ruta_unica()` traga todos los errores con `tryCatch`, así que un fallo se ve como "sin ruta".
- Hay una división por `exposicion_rapida` sin control de cero.
- No hay pruebas automáticas. Las funciones puras (`hora_a_minutos`, `franja_de`, `distancias_m`, `pesos_aristas`) se pueden probar sin construir el grafo.

## 9. Lo que necesito que confirmes

- ¿Seguimos con el orden de la sección 7, o cambiamos prioridades?
- ¿Crear la rama ahora con los puntos 1 a 3, y dejar 4 a 7 para una segunda pasada?
