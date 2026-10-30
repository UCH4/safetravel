# Calibración de la base OSM: resultados y próximos pasos

Pruebas del 29-oct-2026. Rama: `mejora/base-osm-2026`. Muestra: 30 pares de centroides de la grilla, entre 2 y 8 km (semilla 2026).

## Qué se probó

- **Base:** relaciones `route=bus` de OSM en CABA (700 líneas, 11.838 paradas, 33.740 tramos). Script: `R/09_base_osm.R`. La velocidad del bus quedó en 20 km/h.
- **Variantes (12):** velocidad de bus 15 / 20 / 25 km/h × penalización por subida 1 / 3 min × escala de la espera 1 / 0,5. Script: `R/10_calibracion_osm.R`.
- **Referencias:**
  - **r5r** sobre GTFS 2019, 01-oct-2019 14:00. Tiene ruta en 27 de 30 pares. Script: `R/08_benchmark_r5r.R`.
  - **Google Maps**, transporte público, en los 30 pares. Tiene ruta en 30 de 30. Tiempos en `data/google_maps_pares.csv`.
- **Métrica:** tiempo de la opción más rápida de cada método. Se mide el error absoluto mediano frente a cada referencia y la correlación de Spearman (orden de las rutas).

## Resultados

| Velocidad | Subida | Espera | Pares r5r | Error vs r5r (min) | Spearman vs r5r | Error vs Google (min) | Spearman vs Google |
|---|---|---|---|---|---|---|---|
| 15 km/h | 1 o 3 | ×0,5 | 27 | 2,6 | 0,87 | **3,5** | 0,84 |
| **20 km/h** | 1 o 3 | ×1 | 27 | **2,4** | **0,89** | 3,6 | 0,85 |
| 15 km/h | 1 o 3 | ×1 | 27 | 4,8 | 0,88 | 4,3 | 0,86 |
| 20 km/h | 1 o 3 | ×0,5 | 27 | 3,6 | 0,88 | 5,6 | 0,85 |
| 25 km/h | 1 o 3 | ×1 | 27 | 3,5 | 0,88 | 5,8 | 0,87 |
| 25 km/h | 1 o 3 | ×0,5 | 27 | 6,1 | 0,90 | 8,4 | 0,86 |

(Las 12 filas completas están en `data/calibracion_osm.csv`. Con penalización 1 o 3 los tiempos son iguales.)

**Lectura:**

1. **La penalización por subida no cambia los tiempos.** `duracion_min` es viaje + espera + caminata. La penalización solo afecta qué ruta se elige. Hay que calibrarla aparte, con el criterio de riesgo.
2. **Con 30 pares, la elección se empata.** 20 km/h con espera ×1 y 15 km/h con espera ×0,5 tienen errores casi iguales (suma 6,0 y 6,1 min). 20 km/h tiene mejor orden frente a r5r y 15 km/h un poco mejor frente a Google. Con 10 pares la diferencia era más clara; con 30 se achica. **Ninguna variante sale claramente mejor.**
3. **Se mantiene 20 km/h con espera ×1** porque es la que ya está en la base y tiene el mejor orden de rutas frente a r5r. Es una elección razonable, no una prueba concluyente.
4. **Google tarda más que r5r** en 17 de los 27 pares comunes. Google usa horarios vigentes de 2026 y r5r usa los de 2019, así que la diferencia no es solo del modelo.

## Cobertura

- **Par 6:** no tiene ruta en OSM ni en r5r, pero Google encuentra una de 78 min. Hay que revisar qué líneas pasan cerca del origen y del destino.
- **Par 4:** OSM tiene ruta (26,6 min con 20 km/h) y r5r no.
- **Par 12:** r5r no tiene ruta, pero OSM sí (33 min con 15 km/h).
- OSM encuentra ruta en 29 de 30 pares. r5r en 27 de 30.

## Advertencias sobre Google

- Se consultó con **"llegar a las 14:00 del martes 3-nov-2026"** en modo transporte, opción "Óptimo". En el modo *llegar a* las salidas caen entre 12:30 y 12:50, no a las 14:00 que usa la app. Para los tiempos casi no cambia, pero no es exactamente la misma franja.
- Google muestra horarios vigentes de 2026, que pueden diferir de los de 2019.
- Google da una opción por búsqueda (la "Óptima"). No siempre es la más rápida de todas.
- Los tiempos se leyeron del texto de la página (modo transporte, segunda cifra de la fila "Óptimo"). Se verificó contra el título de la ruta en varios pares.

## Qué falta

1. **Pares 6 y 4 y 12:** revisar la cobertura de OSM en esas zonas.
2. **Frecuencias:** las esperas siguen viniendo de GTFS 2019. Es el límite principal de precisión y OSM no lo resuelve. No hay fuente pública vigente que haya podido abrir (ver el plan anterior).
3. **Riesgo:** la calibración no toca el score de riesgo. Hay que verificar que las rutas más seguras se apoyen en tramos que realmente sean más seguros.
4. **Penalización por subida:** calibrar con el criterio de riesgo, no de tiempo.

## Cómo proseguir (propuesta)

1. **Adoptar la base OSM a 20 km/h** como candidata. Su cobertura es mayor que la de r5r y el orden de las rutas coincide bastante. Cambiar la app solo después de revisar los pares sin ruta (punto 1).
2. **Revisar los pares 6, 4 y 12** y la cobertura de OSM en esas zonas.
3. **Decidir la fuente de frecuencias** (2019 u otra). Es el límite principal de precisión.
4. **Calibrar la penalización por subida** con un criterio de riesgo.

## Archivos

- `R/09_base_osm.R`: velocidad del bus en OSM, ahora 20 km/h.
- `R/10_calibracion_osm.R`: grilla de variantes y comparación.
- `R/08_benchmark_r5r.R`: ahora calcula 30 pares (`N_PARES_BENCH = 30`).
- `data/calibracion_osm.csv`: resumen de las 12 variantes.
- `data/calibracion_osm_pares.csv`: tiempos por par y variante, con r5r y Google al lado.
- `data/benchmark_r5r.csv`: r5r en 30 pares.
- `data/google_maps_pares.csv`: tiempos de Google Maps usados como referencia.

Para correr r5r hace falta `JAVA_HOME` apuntando al JDK 21 de Homebrew:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
```
