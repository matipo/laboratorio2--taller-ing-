# NULL-TRADE - Laboratorio 2: Contenerización con Docker y Despliegue en ECS/Fargate

## Integrantes

- Matias Rocha
- Miguel Rocha
- Cristofer Leiva

## Descripción

NULL-TRADE es una plataforma de comercio de videojuegos que opera en tres líneas de negocio: venta de videojuegos físicos y digitales, un marketplace comunitario donde los usuarios pueden vender e intercambiar cuentas, skins y tradeos, y una sección de guías creadas por la comunidad.

El sitio se sirve como contenido estático mediante Nginx dentro de un contenedor Docker, desplegado en Amazon ECS sobre Fargate detrás de un Application Load Balancer, en dos zonas de disponibilidad para alta disponibilidad.

**Todos los pasos detallados, decisiones técnicas, diagrama de arquitectura y comandos de limpieza están en el informe (`informe.pdf`).**

## Estructura del repositorio

```
.
├── Dockerfile          # Imagen Docker basada en nginx:1.27-alpine
├── .dockerignore       # Archivos excluidos del build context
├── nginx.conf          # Configuración de Nginx (try_files para SPA)
├── deploy.sh           # Script de despliegue completo (infrahoraestructura AWS)
├── informe.pdf         # Informe técnico completo
├── capturas/           # Evidencia funcional del despliegue
│   ├── ECR.png         # Imagen en ECR
│   ├── ECS-2.png       # Servicio con runningCount=2
│   ├── ECS-4.png       # Servicio escalado a 4 tareas
│   └── PAGINA.png      # Sitio accesible por el DNS del ALB
└── null-trade/         # Código fuente de la aplicación web
    ├── index.html
    ├── icon.webp
    └── assets/
        ├── index-DlGVERSR.js
        ├── index-FECw4ukq.css
        └── *.webp            # Imágenes de juegos
```

## Despliegue rápido

### 1. Construir la imagen Docker

```bash
docker build -t null-trade:1.0 .
docker run --rm -p 8080:80 null-trade:1.0
# Verificar en http://localhost:8080, luego Ctrl+C
```

### 2. Desplegar en AWS

```bash
bash deploy.sh
```

El script valida prerrequisitos (AWS CLI, Docker, credenciales, imagen local) y despliega toda la infraestructura: VPC, subredes, security groups, IAM role, ECR, ALB, ECS/Fargate.

### 3. Escalar a 4 tareas

```bash
aws ecs update-service --cluster null-trade-cluster --service null-trade-svc --desired-count 4
```

### 4. Limpiar recursos

Todos los comandos de limpieza están detallados en la **Sección 7 del informe (`informe.pdf`)**.

## Requisitos

- AWS CLI configurado con credenciales (`aws configure`)
- Docker instalado y corriendo
- Imagen `null-trade:1.0` construida localmente antes de ejecutar `deploy.sh`