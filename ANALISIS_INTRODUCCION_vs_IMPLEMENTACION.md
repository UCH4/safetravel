# Análisis: Introducción (Grupo 3, Comisión DF) vs. implementación actual

Fecha: 2026-10-18. Fuente del documento: `Introducción_Comisión[DF]_Grupo3 (1).md`.

## 1. Datos (sección 2 del documento)

| Afirmación del documento | Resultado verificado | Estado |
|---|---|---|
| 10 archivos 2016–2025, 1.387.622 registros | 1.387.622 filas en los 10 CSV | ✅ |
| 1.064.417 registros de robos y hurtos | Robo 592.817 + Hurto 471.600 = 1.064.417 | ✅ |
| Coordenadas utilizables en más del 99 % | 99,34 % de robos+hurtos con lat/lon numéricos válidos | ✅ |
| Cobertura de 15 comunas y 48 barrios | 48 barrios en `barrios.geojson`; 2016–2019: 99,97 % de los registros caen dentro de algún barrio | ✅ |
| Excluir 2020–2021 (pandemia) | Implementado (`ANIOS_EXCLUIDOS`) | ✅ |
| Proyección a EPSG:5347 (POSGAR 2007 / UTM 21S) | Implementado | ✅ |

Discrepancias de los datos con el código original (ya corregidas):
- El CSV tiene `latitud`/`longitud`, `franja` y `tipo` (el código asumía `lat`, `lon`, `hora`, y "tipo" sin filtrar).
- Hay valores `NULL`, ceros y coordenadas corruptas (p. ej. −3,4e17). Se filtran antes de asignar barrios.
- 5 de los 48 polígonos de barrios son geométricamente inválidos. Se reparan con `st_make_valid()`. Sin esa reparación la unión falla y la app cae en la grilla sintética sin avisar.

## 2. Grilla de riesgo (sección 2 y 3 del documento)

Lo construido (`R/01_preparar_riesgo.R`):
- Entrenamiento: 2016–2019 y 2022–2023. Ajuste: 2024. Prueba: 2025, usada una sola vez.
- Celdas cuadradas sobre la unión de los barrios, normalización lineal 0–1 respecto de la celda de mayor densidad (como pide el documento).
- Parámetros elegidos con 2024 (Spearman entre riesgo de entrenamiento y conteo real de 2024):

| Tamaño de celda | Peso nocturno 1,0 | 1,5 | 2,0 |
|---|---|---|---|
| 100 m | 0,854 | 0,854 | 0,852 |
| 250 m | 0,939 | 0,939 | 0,939 |
| 500 m | **0,969** | 0,969 | 0,969 |

- Elegido: celda de 500 m, peso nocturno 1,0. Prueba 2025 (Spearman celdas): **0,954**. Grilla final: 906 celdas.

Observaciones importantes:

1. **La ponderación horaria no aporta nada.** Con peso nocturno 1,0, 1,5 o 2,0 el Spearman casi no cambia. Los eventos nocturnos son ~35 % del total; el ajuste no detecta que su distribución espacial aporte información extra sobre la del resto. El documento dice que el riesgo se pondera "según la franja horaria y el día de la semana". La franja horaria no mejora el índice; el día de la semana **no está implementado**.

2. **El criterio de ajuste favorece la celda más grande.** El Spearman crece de forma monótona con el tamaño de celda (0,85 → 0,94 → 0,97) porque las celdas grandes agregan más eventos y suavizan el ruido. Maximizar Spearman lleva a elegir 500 m, la opción más gruesa probada. Para un ruteo, 500 m es una resolución gruesa (cada celda abarca varias cuadras y varias calles, y un desvío puede quedar dentro de la misma celda que la ruta directa). Hay que decidir un criterio que combine poder predictivo y resolución útil, y justificarlo en el informe. Una opción es fijar la resolución mínima y ajustar solo el peso.

3. **El Spearman de 0,954 es alto pero no implica un buen ruteo.** Mide que las celdas con más delitos en 2016–2019 y 2022–2023 siguen siendo las de más delitos en 2025, lo cual es esperable para hot spots persistentes. No mide si desviar una ruta reduce el riesgo efectivo.

4. **La distribución del riesgo es muy sesgada.** Mediana 0,078; 340 de 906 celdas superan 0,1; solo 12 superan 0,5. Con normalización lineal, la mayoría de las celdas queda casi en cero y el mapa se ve plano. El documento pide normalización lineal; si se quiere mantenerla, conviene reportar esta distribución. Una alternativa es normalizar por percentil y documentarla como desviación del método.

## 3. Prototipo y variables (secciones 3 a 7 del documento)

**Discrepancia central de definiciones.** El documento define:
- A = tiempo de respuesta y duración normalizada respecto de la ruta más rápida.
- B = precisión en la evaluación del riesgo (exposición acumulada).
- C = eficiencia computacional y cobertura espacial.
- E = 0,5·A + 0,3·B + 0,2·C.

El código y la especificación original del TP usan:
- A = eficacia (reducción de riesgo vs. ruta directa).
- B = tiempo de respuesta, min(1, 5/t).
- C = robustez de geocodificación.

Ambas versiones usan los mismos pesos, pero con variables distintas. El nombre "tiempo" está en A en el documento y en B en el código. **Hay que decidir cuál es la definición vigente** antes de escribir resultados: no pueden convivir las dos. Hasta que se confirme, no cambié el código de A, B, C ni E.

Otras diferencias con el documento:
- **Muestreo de pares origen-destino.** El documento dice que se ponderó según densidad poblacional por barrio. El código (`generar_puntos_aleatorios`) muestrea uniforme en el bounding box. El archivo `data/raw/poblacion_barrios.csv` ya está descargado, así que la ponderación es implementable.
- **Prueba t.** El documento describe la prueba t pareada. Con los 100 trayectos simulados, solo 6 cambian de ruta y la diferencia está muy sesgada: t de Student da p ≈ 0,064 y Wilcoxon pareado da p ≈ 0,018. La prueba t no es apropiada; ver `INVESTIGACION_DATOS_Y_MEJORAS.md`.
- **Tiempos por resolución.** El documento dice que se midió el tiempo variando la celda (100, 250, 500 m). No está hecho.
- **Motor de ruteo.** La sección 3 menciona OSRM como motor y la sección 1 o la de diseño menciona Google Routes. Hay que unificar el texto.
- **Set de prueba de C.** El documento describe 50 direcciones verificadas. El código tiene 6 placeholder. Pendiente.

## 4. Qué cambió en el código en esta sesión

- `R/00_config.R`: rutas de datos (`RUTA_DATOS`), tipos de delito, periodos de entrenamiento / ajuste / prueba y candidatos de tamaño de celda y peso nocturno.
- `R/01_preparar_riesgo.R`: reescrito según la sección 2 del documento (carga de los 10 años, filtros, asignación a barrios, ponderación horaria, ajuste en 2024, prueba en 2025, guardado de parámetros y métricas como atributos de la grilla).
- `R/app.R`: lee la grilla desde `RUTA_DATOS`.
- `data/raw/`: CSV anuales de CABA, `barrios.geojson` y `poblacion_barrios.csv`.
- `data/grilla_riesgo.rds`: grilla real (500 m, 906 celdas), con parámetros en `attr(, "parametros")`.

Pendiente antes de reportar resultados: volver a correr `R/02_simulacion_resultados.R` con la grilla real (ya no es sintética), cambiar la prueba t por Wilcoxon, y ponderar el muestreo por población.

## 5. Decisiones que necesito de vos

1. ¿Cuál es la definición vigente de A, B, C? (La del documento o la del enunciado original del TP.)
2. ¿Qué criterio usamos para el tamaño de celda? (Solo Spearman favorece 500 m; propongo fijar 250 m como mínimo y ajustar el peso.)
3. ¿Mantenemos la ponderación horaria aunque el ajuste no la justifique, o la reportamos como no significativa?
4. ¿Corremos la simulación de 100 trayectos ahora con la grilla real y el muestreo ponderado por población?
