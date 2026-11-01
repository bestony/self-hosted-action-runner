# Runner autohospedado de GitHub Actions en Docker (Self-Hosted Runner)

Un runner autohospedado de GitHub Actions contenedorizado y multiarquitectura (amd64 / arm64) con soporte nativo para flujos de trabajo en Docker (Docker-outside-of-Docker / DooD) e integración con GitHub Actions Cache Server para aceleración de compilaciones.

**Idiomas / Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **Repositorio en GitHub**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Repositorio en Docker Hub**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

<img src="https://mobile.thematrixcrop.com/p/cKRqSiJRg" width="1" height="1" alt="" />

---

## ¿Por qué elegir este proyecto? (Comparativa)

| Dimensión | Runner alojado en GitHub | Runner autohospedado nativo | Este proyecto |
|---|---|---|---|
| **Coste y minutos de uso** | Facturación por minuto en repos privados (desde $0.008/min). | Ejecución gratuita en su propio hardware. | **Sin costes adicionales por minuto**; aprovecha servidores propios o cloud al máximo. |
| **Hardware y arquitectura** | Configuraciones fijas (habitualmente 2 vCPUs). Los runners ARM o de alto rendimiento son caros. | Depende del host, pero la configuración inicial es manual. | **Control total sobre CPU/RAM**. Soporte nativo multiarquitectura (`amd64`, `arm64` / Apple Silicon / Raspberry Pi). |
| **Despliegue y ciclo de vida** | Cero mantenimiento (gestionado íntegramente por GitHub). | Manual y complejo: descarga de tarball, creación de usuario, servicio systemd y actualizaciones manuales. | **Instalador de una sola línea** (`curl \| bash`). Detección automática de Docker o Podman (Quadlet) y gestión de servicios. |
| **Caché de Actions (`actions/cache`)** | Límite de 10 GB por repositorio; transferencia lenta por internet público. | Sin servidor de caché local integrado (requiere S3/MinIO complejo o falla). | **Servidor de caché compartido integrado** con parche binario y compresión ultrarrápida `zstd`. Almacenamiento en disco local sin límites de cuota. |
| **Limpieza y aislamiento del host** | VM limpia y efímera para cada trabajo. | Se ejecuta directamente en el SO del host, acumulando paquetes residuales y artefactos. | **Aislamiento en contenedores**. Flujos de trabajo mediante Docker-outside-of-Docker (DooD) sin ensuciar el sistema anfitrión. |
| **Permisos de archivos** | Gestionados transparentemente por GitHub. | Tareas de Docker crean archivos con permisos root en el host, provocando errores `EACCES: permission denied`. | **Corrección automática de permisos**. Hooks integrados devuelven automáticamente los archivos root al usuario `runner`. |
| **Escalabilidad y multirrepositorio** | Concurrencia automática sujeta a la cuota de la cuenta. | Mantenimiento manual tedioso para cada instancia en directorios separados. | **Configuración multirunner y multirrepositorio en un solo paso**. Escalado sencillo mediante perfiles de Compose o Podman. |
| **Compatibilidad con Marketplace** | 100% compatible. | Fallos frecuentes por ausencia de `/opt/hostedtoolcache` o herramientas base de compilación. | **Contrato de compatibilidad total**. Toolcache preconfigurado, herramientas esenciales, sudo sin contraseña y diagnóstico `runner-doctor`. |

---

## 1. Instalador interactivo de una sola línea

La forma más sencilla de desplegar runners para repositorios individuales o múltiples con un servidor de caché compartido opcional:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### Características destacadas
- **Verificación previa y configuración automática**: Detecta Docker Engine y Compose v2; instala dependencias automáticamente en Linux (vía `get.docker.com`) y macOS (vía Homebrew).
- **Asistente de configuración interactivo**: Solicita URLs de repositorios/organizaciones, tokens de registro ocultos, nombres de runner y etiquetas. Admite múltiples runners en un solo paso.
- **Servidor de caché compartido integrado**: Despliega un servidor de caché (`falcondev-oss/github-actions-cache-server`) con resolución automática de la IP del host DooD.
- **Seguro y determinista**: Crea `docker-compose.yml` y `.env` con permisos estrictos `chmod 600`. Los tokens de registro nunca se escriben en los archivos Compose.

### Opciones CLI principales
- `--dir <ruta>`: Directorio de instalación (por defecto: `/opt/github-runner` o `$HOME/github-runner`).
- `--non-interactive`: Automatiza el despliegue sin preguntas usando variables de entorno `GHR_*`.
- `--no-start`: Genera archivos de configuración sin iniciar los contenedores.
- `--uninstall`: Detiene contenedores y solicita confirmación para borrar volúmenes persistentes.

> Para hosts Linux que usan Podman en lugar de Docker, utilice nuestro instalador Podman Quadlet:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
> ```
> Consulte [deployments/podman/README.md](deployments/podman/README.md) para más detalles.

---

## 2. Inicio rápido con Docker (Contenedor individual manual)

Para iniciar rápidamente un contenedor de runner sin utilizar el instalador:

### Paso 1: Obtener un token de registro
Genere un token de registro en su repositorio u organización en GitHub:
- **Repositorio**: `Settings` > `Actions` > `Runners` > `New runner`.
- **Organización**: `Organization Settings` > `Actions` > `Runners` > `New runner`.

### Paso 2: Ejecutar el contenedor
Ejecute el siguiente comando en el host:

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

El runner se configurará automáticamente, se registrará ante GitHub y comenzará a procesar trabajos. Las credenciales persisten en el volumen `runner_data`, por lo que reiniciar el contenedor no requiere re-registrarse.

---

## 3. Despliegue con Docker Compose

Puede administrar los runners y el servidor de caché de manera conjunta utilizando Docker Compose:

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
    image: bestony/self-hosted-runner:latest
    restart: unless-stopped
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_1:-${RUNNER_NAME:-}}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_1:-${RUNNER_NAME_PREFIX:-runner-1-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
    volumes:
      - runner_1_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}:${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
    depends_on:
      cache-server:
        condition: service_started
        required: false

  runner-2:
    <<: *runner-base
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_2:-}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_2:-${RUNNER_NAME_PREFIX:-runner-2-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
    volumes:
      - runner_2_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}:${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
    profiles:
      - multi
      - scale
      - all

  cache-server:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:latest
    restart: unless-stopped
    environment:
      API_BASE_URL: ${CACHE_API_BASE_URL:-http://cache-server:3000}
      STORAGE_DRIVER: filesystem
      STORAGE_FILESYSTEM_PATH: /data/cache
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
    volumes:
      - cache_data:/data
    profiles:
      - cache
      - full
      - all

volumes:
  runner_1_data:
  runner_2_data:
  cache_data:
```

### Instrucciones de uso

1. **Preparar configuración**:
   ```bash
   cp .env.example .env
   # Configurar RUNNER_URL y RUNNER_TOKEN en .env
   ```

2. **Iniciar servicios**:
   ```bash
   # Iniciar runner individual (predeterminado)
   docker compose up -d

   # Iniciar 2 runners concurrentes
   docker compose --profile multi up -d

   # Iniciar runner con servidor de caché compartido
   docker compose --profile cache up -d
   ```

3. **Ver registros**:
   ```bash
   docker compose logs -f
   ```

---

## 4. Documentación y guías avanzadas

Para despliegues específicos, especificaciones de arquitectura y operaciones avanzadas, consulte los siguientes documentos:

| Tema | Documento | Descripción |
|---|---|---|
| **Podman + systemd** | [deployments/podman/README.md](deployments/podman/README.md) | Generación de unidades Quadlet, ciclo de vida en arranque con systemd, reglas de firewall y modos de caché. |
| **Servidor de caché compartido** | [deployments/docker-compose/multi-repo-cache/README.md](deployments/docker-compose/multi-repo-cache/README.md) | Arquitectura de caché compartida, enrutamiento DooD con IP del host y aceleración de `actions/cache`. |
| **Aislamiento de múltiples stacks** | [deployments/docker-compose/README.md](deployments/docker-compose/README.md) | Ejecución de varios stacks independientes en un único host sin colisiones de volúmenes o red. |
| **Despliegue en Kubernetes** | [deployments/kubernetes/README.md](deployments/kubernetes/README.md) | Clústeres escalables con StatefulSet, manifiestos Deployment + PVC y configuraciones Kustomize. |
| **CapRover PaaS** | [deployments/caprover/README.md](deployments/caprover/README.md) | Plantillas de aplicación en un clic y configuraciones individuales o multirunner. |
| **Contrato de compatibilidad** | [development.md#8-hosted-runner-compatibility-contract](development.md#8-hosted-runner-compatibility-contract) | Estándares de toolcache (`/opt/hostedtoolcache`), diagnósticos con `runner-doctor` y hooks de permisos. |
| **Arquitectura y variables de entorno** | [development.md](development.md) | Tabla completa de variables de entorno, configuración DooD y compilación de imágenes multiarquitectura. |
