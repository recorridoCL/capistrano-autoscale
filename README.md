# Capistrano::Autoscale

Deploy con Capistrano sobre flotas detrás de un **Auto Scaling Group** en AWS: los servers se descubren desde el **target group** ligado al **Auto Scaling Group**, y se usa un solo task que elige entre usar un deploy lineal o **blue/green** (dos waves por paridad de índice).

## Instalación

En tu `Gemfile`:

```ruby
gem 'capistrano-autoscale'
```

```bash
bundle install
```

## Configuración (Capistrano)

**Capfile** (si aún no lo tienes):

```ruby
require 'capistrano/autoscale'
```

**`config/deploy.rb`** (variables comunes):

```ruby
set :aws_region, ENV.fetch('AWS_REGION')
set :aws_access_owner_id, ENV.fetch('AWS_ACCESS_KEY_ID')
set :aws_secret_owner_access_key, ENV.fetch('AWS_SECRET_ACCESS_KEY')
set :autoscaling_group_name, ENV.fetch('AUTOSCALING_GROUP_NAME')

set :blue_green_min_instances, 2       # default; por debajo → deploy sin waves
set :update_launch_template_ami, true  # default; al final, AMI + nueva versión del launch template

# Tras cada `register_targets`, poll hasta que **todos** los targets del TG estén `healthy`:
# set :register_poll_interval_sec, 5   # default
# set :register_poll_timeout_sec, 120  # default; intentos ≈ ceil(timeout / interval)
```

**`config/deploy/production.rb`** (ejemplo de stage):

```ruby
set :rails_env, 'production'      # usualmente ya está seteado
set :deployment_env, 'production' # required; usado para nombrar la AMI, versión y descripciones
set :instance_type, 't3.medium'   # required; usar la de las instancias del proyecto
set :volume_sizes, [30, 20]       # required; raíz y data, usados al crear AMI
set :deploy_user, 'ubuntu'        # required;

# Llamar esta función en el stage file para cargar servers antes del deploy
setup_servers
```

Sin `setup_servers` en el stage, Capistrano no tendrá la lista de servers ni `:instances` para las tareas de ELB.

---

## Uso principal: `autoscaled:deploy`

Este es el **único entrypoint** que debes usar en CI o a mano:

```bash
bundle exec cap <stage> autoscaled:deploy
```

La gema no expone un “modo alternativo” oficial: el resto de tasks existen para componer este flujo o para casos muy puntuales.

### Qué hace, en orden

1. **Valida** la configuración del poll de salud tras registrar (`:register_poll_interval_sec` / `:register_poll_timeout_sec` deben ser enteros positivos).
2. **Toma un snapshot** de la flota: instancias registradas en el target group del ASG (vía `describe_target_health`), ordenadas por `instance_id`. Ese orden fija las waves en blue/green.
3. **Si no hay ninguna instancia** en el TG → el deploy falla con error explícito.
4. **Si el número de instancias es menor que `blue_green_min_instances`** (default 2) → ejecuta un **`deploy` normal** sobre **todas** las instancias del snapshot (sin sacar nadie del balanceador).
5. **Si hay suficientes instancias** → ejecuta **blue/green**:
   - Parte el snapshot en dos listas: índices **pares** (wave `even`) e **impares** (wave `odd`), en ese orden.
   - Para **cada** wave, en subprocesos separados de Capistrano (misma variable de entorno interna con los IDs fijos de esa wave):
     - `deploy:deregister_instances_from_load_balancer` → quita **solo** esas instancias del TG;
     - `deploy` → despliegue contra **solo** esas instancias;
     - `deploy:register_instances_in_load_balancer` → vuelve a registrar esas mismas instancias y **espera** a que **todo** el target group esté healthy (poll con timeout).
   - Así, deregister / deploy / register de una wave **no** dependen de un nuevo listado del TG entre pasos (evita mezclar miembros de waves si el TG cambia entre llamadas).
6. **Si `update_launch_template_ami` es true** (default) → `deploy:new_ami_configuration`: crea AMI a partir de una instancia del ASG, nueva versión del launch template y la deja como default.

### Deploy “simple” (sin blue/green)

Menos de `blue_green_min_instances` instancias en el TG (típico: una sola máquina en QA/staging): un solo `deploy` sobre toda la flota del snapshot, sin deregister/register.

### Blue/green (dos waves)

Dos o más instancias en el TG: waves **even** y **odd** según la posición en la lista **ordenada por `instance_id`**. El orden de las waves **no** es configurable (diseño fijo para que los IDs por wave sean estables).

### `cap <stage> deploy` sin el wrapper

Un `deploy` directo **no** ejecuta el wrapper: usa lo que `setup_servers` resuelva en ese momento (toda la flota del TG si no hay env de wave). Las waves y los subconjuntos por instancia las arma **solo** `autoscaled:deploy` / `autoscaled:blue_green_deploy` vía la env interna `CAP_BLUE_GREEN_INSTANCE_IDS` en los subprocesos; **no** hace falta (ni conviene) setearla a mano.

---

## Cómo se descubren las instancias

- El ARN del target group sale del Auto Scaling Group (`target_group_arns.first`).
- Se consideran **todos** los targets devueltos por `describe_target_health` (no solo los que están `healthy` en ese momento); de ahí se obtienen IDs, se ordenan, y se resuelven IPs con EC2.
- Cualquier instancia **registrada en el target group** entra en el snapshot, aunque no esté en el ASG (útil para cron, workers, etc., si comparten el mismo TG).
- En blue/green, **deregister y register** usan exactamente la lista de IDs de la wave actual (`:instances` derivado de `CAP_BLUE_GREEN_INSTANCE_IDS` en cada subproceso).

---

## Otras tareas (referencia)

| Task | Rol |
|------|-----|
| `autoscaled:deploy` | **Orquestador** principal (ver arriba). |
| `autoscaled:blue_green_deploy` | Solo las dos waves; pensado para ser invocado desde `autoscaled:deploy` (requiere `:all_target_group_instances`). |
| `deploy:deregister_instances_from_load_balancer` | Quita del TG los `:instances` del proceso actual. |
| `deploy:register_instances_in_load_balancer` | Registra `:instances` en el TG y espera salud global del TG. |
| `deploy:new_ami_configuration` | AMI + versión de launch template; la invoca el wrapper al final si `update_launch_template_ami`. |

---

## Casos especiales

- **Una sola instancia**: deploy normal; sin waves ni deregister/register.
- **Instancias extra en el TG** (p. ej. cron): entran en el conteo y en la partición even/odd como cualquier otro target del TG.

## Licencia

MIT. See [MIT License](http://opensource.org/licenses/MIT).
