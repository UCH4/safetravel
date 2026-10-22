# TODO: pendientes de código y documento

Estado de referencia: la app funciona con la grilla real (500 m, 906 celdas). Ver [GUIA_BETA.md](GUIA_BETA.md) para correrla.

Prioridad: **[A]** bloquea resultados; **[B]** necesario para la entrega; **[C]** mejora.

---

## Decisiones que hay que tomar primero

1. **[A] Definición de A, B y C.** El documento (secciones 4 a 7) y el código no coinciden:
   - Documento: A = tiempo normalizado, B = precisión/exposición al riesgo, C = eficiencia computacional.
   - Código y enunciado original: A = eficacia (reducción de riesgo), B = tiempo de respuesta, C = robustez de geocodificación.
   - Los pesos de E son iguales en ambos (0,5 / 0,3 / 0,2), así que el cambio de nombres altera el significado de E.
   - Hay que elegir una versión y aplicarla en `R/funciones_core.R`, `R/app.R`, `R/02_simulacion_resultados.R` y en el documento.

2. **[A] Criterio de tamaño de celda.** El ajuste con Spearman en 2024 elige 500 m porque el Spearman sube con el tamaño de celda (0,85 → 0,94 → 0,97). Propuesta: fijar 250 m como mínimo y ajustar solo el peso nocturno.

3. **[B] Ponderación horaria.** Con el ajuste actual, el peso nocturno no mejora el Spearman (1,0 / 1,5 / 2,0 dan el mismo resultado). ¿Se mantiene como parámetro sin efecto o se reporta como no significativa?

---

## Código

- **[A] Simulación con la grilla real.** `data/resultados_simulacion.csv` y `comparacion_riesgo.png` vienen de la grilla sintética. Volver a correr `Rscript R/02_simulacion_resultados.R`.
- **[A] Prueba estadística.** `R/02_simulacion_resultados.R` (función `analizar_resultados`) usa `t.test` pareado. Con 100 trayectos, solo 6 cambian de ruta y la diferencia está muy sesgada (asimetría ~6,9): t de Student p ≈ 0,064, Wilcoxon pareado p ≈ 0,018. Cambiar a `wilcox.test(..., paired = TRUE, alternative = "greater")` y reportar también el efecto solo en los trayectos que cambiaron.
- **[A] Muestreo de pares origen-destino.** Hoy es uniforme en el bounding box (`generar_puntos_aleatorios`). El documento dice que se pondera por densidad poblacional de barrio: usar `data/raw/poblacion_barrios.csv` y los polígonos de barrios para muestrear.
- **[B] Heurística de desvío.** `R/funciones_core.R` (`proponer_waypoints_desvio`, aprox. línea 99) suma +0,0027° al centroide. El comentario dice que el desvío se orienta hacia la celda vecina de menor riesgo, pero el código no lo hace, y el punto puede caer en otra celda riesgosa. Corregir la lógica y el comentario.
- **[B] Set de prueba de C.** `R/02_simulacion_resultados.R` (`construir_set_prueba_geocodificacion`) tiene 6 direcciones placeholder. El documento dice 50 direcciones reales con coordenadas verificadas a mano. También revisar la tolerancia de 100 m.
- **[B] Aviso de grilla sintética en la app.** Hoy solo se avisa en consola. Mostrar un aviso en pantalla (`shiny::showNotification`) cuando la grilla es sintética.
- **[B] Día de la semana.** El documento dice que la exposición se pondera por franja y día de la semana. Solo está implementada la franja nocturna. Decidir si se implementa o se quita del documento.
- **[C] Tiempos por resolución.** El documento dice que se midió el tiempo de respuesta con celdas de 100, 250 y 500 m. No está hecho.
- **[C] Normalización.** Con normalización lineal, la mediana del riesgo es 0,08 y solo 12 de 906 celdas superan 0,5. Evaluar normalización por percentil y documentar la desviación.
- **[C] Arranque lento.** `app.R` geocodifica las 6 direcciones de C al iniciar. Cachear el resultado en `data/` o calcularlo bajo demanda.
- **[C] Paleta de colores.** `app.R`: `colorNumeric` se crea dentro de la fórmula de `addPolygons`, así que se recalcula por cada polígono. Crearla una vez.
- **[C] Código muerto.** `R/02_simulacion_resultados.R`: `incProgress <- NULL` no hace nada.
- **[C] Dependencias.** `googlePolylines` y `httr` se usan en la rama Google pero no están en `paquetes_requeridos` (`R/00_config.R`).
- **[C] Errores silenciosos.** `obtener_grilla_riesgo()` oculta el error real (con `tryCatch`) y cae en la sintética. Mostrar el mensaje de error completo en consola.
- **[C] Cobertura de datos 2018.** ~9 % de los registros de 2018 no tiene coordenadas (`NULL`). Documentar en el informe.
- **[C] Pruebas.** No hay pruebas automáticas. Al menos: `calcular_eficacia`, `calcular_tiempo_respuesta`, `peso_franja` y `construir_grilla_desde_eventos` sobre datos de juguete.

---

## Documento (`materiales_y_metodos.md` e `Introducción_Comisión[DF]_Grupo3`)

- **[A] Definiciones de A, B, C y E.** Ver decisión 1. Unificar en las secciones 4 a 7 de la Introducción y en `materiales_y_metodos.md`.
- **[A] Sección 8 (diseño experimental).** Dice "prueba t de Student pareada" y "ponderando por densidad poblacional". Cambiar a la prueba que se use (Wilcoxon si se aplica el paso de código) y describir el muestreo real.
- **[A] Resultados.** No hay ningún número de resultados todavía. Completar después de volver a correr la simulación con la grilla real.
- **[B] Sección 2 (fuentes y preprocesamiento).** Dice que la grilla pondera por franja **y día de la semana**. Revisar según la decisión 3.
- **[B] Sección 2 (normalización).** Documentar la distribución sesgada del riesgo (mediana 0,08) y la alternativa, si se adopta.
- **[B] Motor de ruteo.** La Introducción menciona Google Routes en la sección de diseño y OSRM en la descripción del prototipo. Unificar: el motor por defecto es OSRM.
- **[B] Fechas y encabezados.** "Fecha de entrega: 03/09/26" ya pasó (hoy es 18/10/2026). Y en el historial aparece "06/010/2026" (typo). Revisar con el profe.
- **[B] Referencias.** Verificar que los enlaces del documento funcionen. En particular el informe ejecutivo del Mapa del Delito 2025 (`cdn.buenosaires.gob.ar/.../2025_informe_ejecutivo.pdf`), que no verifiqué.
- **[C] Cifras verificadas.** Las cifras de la sección 2 (1.387.622 registros, 1.064.417 robos y hurtos, 99 % de coordenadas válidas, 48 barrios) están verificadas con los datos descargados. Anotar la fuente exacta (fecha de descarga) en el documento.
- **[C] Limitaciones.** Agregar: cifra negra (ya está), concentración de la grilla gruesa, uso de OSRM demo, y que el Spearman mide persistencia espacial, no eficacia de ruteo.
