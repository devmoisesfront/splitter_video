# 🍳 El CHEFF — Video Splitter

![Python](https://img.shields.io/badge/Python-3.10+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![FFmpeg](https://img.shields.io/badge/FFmpeg-Auto--Install-green)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

**El CHEFF** es una aplicación de escritorio para Windows que divide automáticamente videos en clips por tiempo, organizada por carpetas de días, meses o años.

Diseñada para procesar grandes volúmenes de video sin configuración manual.

---

## ✨ Características

🧠 Detección automática de estructura de carpetas  
📁 Procesa carpetas por:

- Día
- Mes
- Año

🎬 División de videos por tiempo configurable  
⚡ Instalación automática de FFmpeg  
📊 Resumen visual por día  
🟢 Estados de procesamiento (Pendiente / Parcial / Procesado)  
⏹️ Control de ejecución con hilos  
📜 Log detallado en tiempo real  
🚀 No requiere instalar dependencias externas  

---

## 🖥️ Interfaz

- Panel lateral de configuración
- Tabla de resumen por días
- Barra de progreso
- Consola de logs
- Filtros por estado

---

## 📦 Instalación

### Opción 1 — Ejecutar desde código

```bash
git clone https://github.com/tuusuario/el-cheff-video-splitter.git
cd el-cheff-video-splitter
python main.py
