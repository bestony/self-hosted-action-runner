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

## Instalador interactivo de una sola línea

La forma más sencilla de desplegar runners para repositorios individuales o múltiples con un servidor de caché compartido opcional:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### Características principales
- **Verificación previa y dependencias**: Comprueba la disponibilidad de Docker Engine, Docker Compose v2 y la conexión con el demonio. Ofrece instalación automática en Linux (mediante `get.docker.com`) y configuración en macOS vía Homebrew.
- **Asistente de configuración interactivo**: Solicita URLs de repositorios u organizaciones, tokens de registro ocultos, prefijos de nombres y etiquetas. Permite configurar múltiples runners en un solo despliegue.
- **Servidor de caché compartido**: Despliega y configura opcionalmente `ghcr.io/falcondev-oss/github-actions-cache-server:latest` con detección automática de la IP del host DooD.
- **Compose determinista y seguro**: Genera archivos `docker-compose.yml` y `.env` con permisos estrictos `chmod 600`. Los tokens nunca se insertan directamente en los archivos Compose.
- **Verificación automática de estado y registros**: Inicia el stack y monitoriza los registros de registro para verificar la conectividad del runner con GitHub.

### Opciones de línea de comandos del instalador
- `--dir <ruta>`: Directorio de instalación (por defecto: `/opt/github-runner` para root, `$HOME/github-runner` para usuarios estándar).
- `--non-interactive`: Automatiza el despliegue sin preguntas interactivas usando variables de entorno `GHR_*`.
- `--no-start`: Genera los archivos de configuración y la estructura de directorios sin iniciar los contenedores.
- `--skip-docker-install`: Omite los intentos de instalación automática de Docker y el plugin Compose.
- `--uninstall`: Detiene y elimina contenedores, solicitando confirmación para borrar volúmenes persistentes.
- `--debug`: Habilita registros detallados de depuración.
- `-h, --help`: Muestra la ayuda y opciones disponibles.

### Ejemplo de uso interactivo (predeterminado)

Ejecute el comando sin variables `GHR_*` ni opciones adicionales. El instalador lee sus respuestas desde el terminal (`/dev/tty`), funcionando sin problemas mediante `curl | bash`. Presione Enter para aceptar el valor predeterminado. El campo de token se oculta durante la escritura.

```text
$ curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash

==> [3/6] Collecting configuration
Enter installation directory [default: /home/me/github-runner]:

--- Configuring Runner #1 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org/repo-a
GitHub Runner Registration Token:
Runner name prefix [default: repo-a-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 2
Add another repository/org runner? [y/N]: y

--- Configuring Runner #2 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org
GitHub Runner Registration Token:
Runner name prefix [default: my-org-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 1
Add another repository/org runner? [y/N]:

--- Cache Server Configuration ---
Enable shared GitHub Actions cache server? [Y/n]:
Select cache URL mode: [1] Internal (http://cache-server:3000) or [2] Host IP (reachable by container jobs) [default: 1]:
Runner container image [default: ghcr.io/bestony/self-hosted-action-runner:latest]:

(configuration summary, tokens masked)
Write configuration and continue? [Y/n]:
```

> **Nota**: Obtenga el token de registro desde **Settings > Actions > Runners > New self-hosted runner** en su repositorio u organización. El token expira después de 1 hora, pero solo es necesario durante el registro inicial.

Si vuelve a ejecutar el instalador en el mismo directorio, mostrará los runners existentes y le permitirá elegir entre `[A]dd runners` (añadir runners), `[R]econfigure from scratch` (reconfigurar desde cero) o `[Q]uit` (salir).

### Ejemplo no interactivo (CI / Automatización)

Utilice `--non-interactive` únicamente cuando no haya un operador en el terminal. En este modo, el instalador lee las variables `GHR_*` y no solicita confirmaciones:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | \
  GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
  GHR_RUNNER_1_TOKEN="YOUR_REPO_A_TOKEN" \
  GHR_RUNNER_1_INSTANCES=2 \
  GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
  GHR_RUNNER_2_TOKEN="YOUR_REPO_B_TOKEN" \
  GHR_CACHE=1 \
  bash -s -- --non-interactive --dir /opt/github-runner
```

---

## Instalador para Podman + systemd (Quadlet)

Los hosts Linux que utilicen Podman en lugar de Docker Engine pueden utilizar `install-podman.sh`. Este script genera archivos de unidad [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) para que **systemd** administre el ciclo de vida del servicio e inicie el stack en el arranque del sistema:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
```

Comparte los mismos prompts interactivos, variables `GHR_*` y contrato `.env` con `install.sh`; únicamente difiere el formato de unidad y el gestor de ciclo de vida:

| Característica | `install.sh` (Docker) | `install-podman.sh` (Podman) |
|---|---|---|
| **Unidad de despliegue** | `docker-compose.yml` + `.env` | Archivos Quadlet `.container` + `.env` |
| **Gestor de ciclo de vida** | `docker compose` | systemd (`systemctl`, `journalctl`) |
| **Inicio en arranque** | Política `restart:` de los contenedores | `[Install] WantedBy=multi-user.target default.target` en cada unidad |
| **Requisitos** | Docker Engine + Compose v2 | Linux con systemd como PID 1, Podman rootful >= 4.4 |
| **Instancias por destino** | `--instances`, `GHR_RUNNER_<n>_INSTANCES` | Mismo soporte |
| **Subcomandos** | `--uninstall` | `--status`, `--start`, `--stop`, `--restart`, `--upgrade`, `--uninstall` |

```bash
# Despliegue no interactivo para entornos con Podman preexistente
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | \
  sudo bash -s -- --non-interactive --dir /opt/github-runner --skip-podman-install
```

### Particularidades de Podman
- **Versión mínima**: Quadlet está disponible a partir de Podman 4.4. El instalador instala Podman mediante el gestor de paquetes de la distribución si falta, comprueba la versión y verifica `podman-system-generator`.
- **Arranque sin `systemctl enable`**: Dado que las unidades Quadlet son generadas dinámicamente, systemd no permite habilitarlas directamente. La directiva `[Install] WantedBy=` dentro de la unidad generada es lo que asegura el inicio al encender el sistema.
- **Actualizaciones**: `--upgrade` descarga las últimas versiones de `RUNNER_IMAGE` / `CACHE_IMAGE` y reinicia cada unidad; si se define `AUTO_UPDATE=1`, se añade `AutoUpdate=registry` en Quadlet.
- **Servidor de caché**: Modo `internal` (predeterminado: accesible como `http://cache-server:3000/` dentro de la red del stack sin exponer puertos en el host) o `host` (publica `<puerto>:3000` para tareas que usan `container:`). Seleccionable mediante `GHR_CACHE_MODE`.
- **Tareas en contenedores (DooD)**: El socket de Podman del host se monta tanto en `/var/run/docker.sock` como en `/run/podman/podman.sock`, manteniendo la compatibilidad con comandos estándar de `docker`.
- **Cortafuegos del host**: Los contenedores deben poder acceder a `https://api.github.com` (el host debe reenviar tráfico desde la red de contenedores). El script verifica la conectividad antes de iniciar y muestra la regla necesaria (por ejemplo, `sudo ufw route allow in on podman1`).
- **Política de reintentos**: Las unidades configuran `StartLimitIntervalSec=0` y `RestartSec=10`, permitiendo reintentar la conexión cada diez segundos en caso de problemas de red en lugar de quedar en estado fallido (`failed`) en systemd.

Para más información, consulte [deployments/podman/README.md](deployments/podman/README.md).

---

## Matriz de opciones de despliegue

| Topología | Docker Compose | CapRover | Kubernetes | Podman + systemd |
|---|---|---|---|---|
| **Runner individual** | [docker-compose.yml](docker-compose.yml) | [Guía de App individual](deployments/caprover/README.md) | [Deployment + PVC](deployments/kubernetes/README.md#option-b-single-runner-deployment) | [Despliegue Podman](deployments/podman/README.md) |
| **Múltiples Runners (Independientes)** | [docker-compose.multi.yml](deployments/docker-compose/docker-compose.multi.yml) | [Configuración multi-app](deployments/caprover/README.md#option-b-independent-single-runner-apps) | [Clúster StatefulSet](deployments/kubernetes/README.md#option-a-scalable-cluster-statefulset) | [Añadir runners posteriormente](deployments/podman/README.md#adding-runners-later) |
| **Múltiples Runners + Caché compartida** | [Compose con caché multirrepositorio](deployments/docker-compose/multi-repo-cache/README.md) | [Plantilla de un clic](deployments/caprover/multi-repo-cache/README.md) | [Manifiestos Kustomize](deployments/kubernetes/multi-repo-cache/README.md) | [Modos de servidor de caché](deployments/podman/README.md#cache-server-modes) |

---

## 1. Inicio rápido (Contenedor individual manual)

Para iniciar rápidamente un contenedor de runner con `docker run`:

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

El runner se configurará automáticamente, se registrará ante GitHub y comenzará a escuchar trabajos. Las credenciales persisten en el volumen `runner_data`, por lo que reiniciar el contenedor no requiere un nuevo registro.

---

## 2. Uso con servidor de caché

Esta imagen soporta servidores de caché externos para GitHub Actions (como [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)). La imagen incluye un parche binario para `ACTIONS_RESULTS_URL` e integra `zstd` para una compresión de alto rendimiento.

### Cómo habilitar la caché

Establezca la variable de entorno `ACTIONS_RESULTS_URL`:

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -e ACTIONS_RESULTS_URL="http://cache-server:3000/" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

Al configurar `ACTIONS_RESULTS_URL`:
1. Los pasos de workflow con `actions/cache` guardan y restauran artefactos directamente con su servidor de caché.
2. Las actualizaciones automáticas oficiales quedan deshabilitadas (`--disableupdate`) para no sobrescribir el parche interno de caché.
3. Si los flujos de trabajo ejecutan acciones en contenedor, asegúrese de que `ACTIONS_RESULTS_URL` sea accesible desde la red del host (por ejemplo, `http://host.docker.internal:3000/` o la IP de su host).

---

## 3. Configuración con Docker Compose

Puede administrar el runner y el servidor de caché de manera conjunta utilizando Docker Compose.

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
    build:
      context: .
      dockerfile: Dockerfile
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
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
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
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
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
#   ports:
#     - "${CACHE_PORT:-3000}:3000"
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
  runner_3_data:
  runner_4_data:
  cache_data:
```

### Instrucciones de uso

1. Crear un archivo `.env`:
   ```bash
   cp .env.example .env
   ```
2. Configurar `RUNNER_URL` y `RUNNER_TOKEN` en `.env`.
3. Iniciar los servicios:
   ```bash
   # Iniciar una sola instancia de runner (por defecto)
   docker compose up -d

   # Iniciar 2 instancias de runner en paralelo
   docker compose --profile multi up -d

   # Escalar a 4 instancias de runner concurrentes
   docker compose --profile scale up -d

   # Iniciar runner con servidor de caché
   docker compose --profile cache up -d
   ```
4. Consultar los registros:
   ```bash
   docker compose logs -f
   ```

---

## 4. Ejecución de múltiples stacks independientes en un solo host

Puede ejecutar varios stacks de runners independientes en una misma máquina anfitriona sin colisiones:

- **Nombres de proyecto aislados**: Cada stack utiliza un nombre único de proyecto Docker Compose (vía `COMPOSE_PROJECT_NAME` en `.env` o la directiva `name:` en `docker-compose.yml`). El instalador genera nombres deterministas y libres de colisión (`ghr-<dir>-<sha256:8>`).
- **Nombres dinámicos de contenedor**: Se omiten los atributos estáticos `container_name`. Compose asigna nombres dinámicos con el formato `<proyecto>-<servicio>-<índice>`.
- **Aislamiento de red**: Cada stack crea su propia red bridge aislada, previniendo interferencias en resolución DNS o enrutamiento.
- **Aislamiento de volúmenes y credenciales**: Los volúmenes con nombre (`runner_data`, `cache_data`, etc.) están delimitados por proyecto, asegurando que las credenciales y bases de datos SQLite nunca se mezclen.
- **Paridad de espacios de trabajo**: Los directorios de trabajo de las tareas utilizan rutas acotadas (`${PWD}/work/<runner>` o `<directorio_instalación>/work/runner-<n>`), garantizando que los montajes del host para DooD no interfieran entre sí.
- **Puertos de caché independientes**: En modo interno, los runners acceden a la caché a través de la red del proyecto sin enlazar puertos del host; en modo IP del host, se asignan puertos diferenciados automáticamente.

---

## 5. Compatibilidad con runners alojados por GitHub

Las acciones del GitHub Marketplace están diseñadas para ejecutarse en las imágenes oficiales de runners alojados por GitHub y asumen ciertas convenciones que un contenedor base no posee. La falta de estas convenciones genera errores de permisos como `EACCES: permission denied, mkdir '/opt/hostedtoolcache'` (`ruby/setup-ruby`, `actions/setup-python`) o `EACCES: permission denied, stat '/root/.gitconfig'` (`actions/checkout`).

Esta imagen proporciona estas convenciones mediante un contrato verificado en cada inicio del contenedor:

| Convención | Implementación en la imagen |
|---|---|
| **Identidad del runner** | El proceso se ejecuta como el usuario sin privilegios `runner` con `HOME=/home/runner` y permisos `sudo` sin contraseña. |
| **Caché de herramientas** | `RUNNER_TOOL_CACHE` y `AGENT_TOOLSDIRECTORY` apuntan a `/opt/hostedtoolcache`, con propiedad del usuario `runner`. Las herramientas se almacenan en el volumen persistente `/runner` (`/runner/_tool-cache`), evitando descargas duplicadas. |
| **Permisos del espacio de trabajo** | Un hook de trabajo (`/opt/runner-hooks/fix-workspace-ownership.sh`) reasigna automáticamente al usuario `runner` los archivos creados como root en el espacio de trabajo, `RUNNER_TEMP` y la caché de herramientas, antes y después de cada trabajo. |
| **Herramientas base** | Docker CLI con plugins Buildx y Compose (a través de `/var/run/docker.sock`), GitHub CLI (`gh`), `git`, `git-lfs`, `curl`, `wget`, `jq`, `zip`, `unzip`, `xz`, `zstd`, `rsync`, `openssh-client`, `python3`. |
| **Compilación nativa** | Incluye `build-essential`, `pkg-config` y cabeceras esenciales (`libssl-dev`, `libyaml-dev`, `libffi-dev`, `libreadline-dev`, `libgmp-dev`, `zlib1g-dev`) para compilar gemas de Ruby, módulos nativos de Node.js y paquetes de Python en C. |
| **Configuración regional** | `LANG=C.UTF-8`. |

> Para usar `gh` en un trabajo, asigne un token como `env: GH_TOKEN: ${{ github.token }}`. Si un flujo necesita paquetes del sistema adicionales de forma puntual, ejecute `sudo apt-get update && sudo apt-get install -y <paquete>` directamente en un paso, al igual que en un runner oficial.

### Puntos de extensión

Si un flujo de trabajo requiere herramientas adicionales, puede extender el comportamiento mediante variables de entorno sin reconstruir la imagen:

| Variable | Valor predeterminado | Descripción |
|---|---|---|
| `RUNNER_EXTRA_APT_PACKAGES` | - | Paquetes apt a instalar al arrancar el contenedor (separados por espacios o comas), por ejemplo `libpq-dev libsqlite3-dev`. |
| `RUNNER_WRITABLE_PATHS` | - | Rutas absolutas separadas por dos puntos. El contenedor creará los directorios y asignará la propiedad al usuario `runner` (directorios del sistema como `/usr` están restringidos). |
| `RUNNER_INIT_DIR` | `/opt/runner-init.d` | Cada archivo `*.sh` en este directorio se ejecutará con `bash` antes de iniciar el runner. Permite montar scripts personalizados. |
| `RUNNER_TOOL_CACHE` | `/opt/hostedtoolcache` | Ruta de la caché de herramientas. No la modifique salvo estricta necesidad, ya que los binarios precompilados de Ruby y Python integran esta ruta por defecto. |
| `RUNNER_TOOL_CACHE_PERSIST` | `true` | Establecer en `false` para conservar la caché únicamente en la capa efímera del contenedor. |
| `FIX_WORKSPACE_OWNERSHIP` | `true` | Establecer en `false` para desactivar el hook de corrección de permisos. |
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | Script de corrección | Permite especificar un script personalizado antes de iniciar el trabajo. |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | Script de corrección | Permite especificar un script personalizado tras finalizar el trabajo. |

> Cualquier incidencia en un punto de extensión genera una advertencia en el registro sin interrumpir el inicio del runner.

### Diagnóstico de salud

El entrypoint ejecuta `runner-doctor` con el usuario `runner` antes de iniciar el servicio. Si no se satisface alguna convención, el registro reportará una línea con `FAIL` y la causa detectada. Para comprobar el estado en un contenedor en ejecución:

```bash
docker exec -u runner <contenedor> runner-doctor
```

### Trabajos en paralelo

Para ejecutar trabajos matriciales en paralelo, registre múltiples runners: ejecute nuevamente el instalador en el mismo directorio y seleccione `[A]dd runners`. Cada runner ejecuta un único trabajo a la vez.

---

## 6. Documentación adicional

Para obtener información detallada, consulte:
- [deployments/podman/README.md](deployments/podman/README.md): Despliegue con Podman + systemd (Quadlet), estructura de unidades, modos de caché, desinstalación y rollback.
- [development.md](development.md): Arquitectura interna, referencia de variables de entorno, configuración DooD, compilación de imágenes multiplataforma, despliegue en Kubernetes y CapRover, y automatización CI/CD.
- [Repositorio en GitHub](https://github.com/bestony/self-hosted-action-runner): Código fuente, notas de versión y seguimiento de incidencias.
