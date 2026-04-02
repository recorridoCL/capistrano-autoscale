# Capistrano::Autoscale

Herramientas para deploys con Capistrano sobre Auto Scaling Groups en AWS, usando el target group como fuente de servers y soportando deploy normal o blue/green (por paridad `even/odd`).

## Instalación

En tu `Gemfile`:
```ruby
gem 'capistrano-autoscale'
```
Luego:
```bash
bundle install
```

## Configuración mínima (Capistrano)

En `Capfile` (si no lo tienes ya):
```ruby
require 'capistrano/autoscale'
```

En `config/deploy.rb` (variables comunes):
```ruby
set :aws_region, ENV.fetch('AWS_REGION')                             # required;
set :aws_access_owner_id, ENV.fetch('AWS_ACCESS_KEY_ID')             # required;
set :aws_secret_owner_access_key, ENV.fetch('AWS_SECRET_ACCESS_KEY') # required;
set :autoscaling_group_name, ENV.fetch('AUTOSCALING_GROUP_NAME')     # required;
set :blue_green_min_instances, 2     # default; mínimo para habilitar blue/green
set :update_launch_template_ami, true # default; al final de autoscaled:deploy, crear AMI y actualizar launch template
# Opcional — tras register en el TG, esperar a que todos los targets estén healthy (poll):
# set :register_poll_interval_sec, 5   # default
# set :register_poll_timeout_sec, 120  # default; max_attempts = ceil(timeout/interval)
```

En `config/deploy/production.rb` (ejemplo):
```ruby
set :rails_env, 'production'      # usualmente ya está seteado
set :deployment_env, 'production' # required; usado para nombrar la AMI, versión y descripciones
set :instance_type, 't3.medium'   # required; usar la de las instancias del proyecto
set :volume_sizes, [30, 20]       # required; raíz y data, usados al crear AMI
set :deploy_user, 'ubuntu'        # required;

# Llamar esta función en el stage file para cargar servers antes del deploy
setup_servers
```

## Cómo se descubren los servers

- La gema toma el ARN del target group desde el Auto Scaling Group y lista los targets healthy (`describe_target_health`).
- Cualquier instance registrada en el target group se incluye, aunque no pertenezca formalmente al ASG (útil para instancias como la cron, o instancias de sidekiq (posiblemente)).
- Deploy normal (sin la env de IDs de wave): Capistrano usa **todas** las instancias del target group en ese momento.
- Blue/green: el wrapper toma un snapshot al inicio, parte en dos waves fijas (índices pares luego impares en la lista ordenada por `instance_id`) y pasa la lista fija de IDs a cada subprocess vía variable de entorno interna (`CAP_BLUE_GREEN_INSTANCE_IDS`).

## Deploys
El deploy funciona a través de un único wrapper task:
```bash
bundle exec cap production autoscaled:deploy
```

Este se adecua a cada caso como vemos a continuación:

### Deploy normal (sin blue/green, menos del "mínimo" de instancias)
Cuando el target group tiene una sola instance (o cuando no se cumple `blue_green_min_instances`):
```bash
bundle exec cap production autoscaled:deploy
```
El wrapper detecta que no hay instancias suficientes y ejecuta `deploy` normal sobre **toda** la flota del TG; al final del wrapper (común a ambas rutas) puede ejecutarse `deploy:new_ami_configuration` según `update_launch_template_ami`.

### Blue/green por paridad
Con 2 o más instances en el target group, el wrapper:
1) Cuenta instances del target group.
2) Si hay suficientes, toma un snapshot de los IDs en el target group, corre dos waves en orden fijo (even luego odd por índice), y para cada subprocess pasa la lista fija de IDs (variable de entorno interna). Así el deregister/deploy/register no depende de un nuevo snapshot del TG entre pasos.
3) Cuando termina la ruta elegida (deploy normal o blue/green), si `update_launch_template_ami` es true, el wrapper hace `invoke deploy:new_ami_configuration` en el mismo proceso de Capistrano.

Un `cap ... deploy` directo (sin wrapper) usa toda la flota del TG en ese momento; las waves y los subconjuntos por instancia solo las define el wrapper vía la env de IDs.

## Tareas incluidas

- `autoscaled:deploy`: wrapper que decide normal vs. blue/green según el conteo del target group.
- `autoscaled:blue_green_deploy`: las dos waves (even, odd); pensado para invocarse desde `autoscaled:deploy` (usa `:all_target_group_instances`). La AMI la dispara solo `autoscaled:deploy` al final si corresponde.
- `deploy:register_instances_in_load_balancer`: registra los `:instances` en el TG y espera health check (pensado para invocarse desde el flujo `autoscaled:deploy` / blue-green, no como task aislada).
- `deploy:deregister_instances_from_load_balancer`: los saca del target group.
- `deploy:new_ami_configuration`: crea AMI desde una instance del ASG, genera nueva versión del Launch Template y la deja como default (requiere `:volume_sizes`, `:instance_type`, `:autoscaling_group_name`).

## Casos especiales
- **Una sola instance**: el deploy normal incluye esa única instancia; el wrapper hará deploy sin waves ni deregistro/registro.
- **Instance extra fuera del ASG (cron/sidekiq) pero en el target group**: se incluye en el conteo y en las waves porque el discovery se basa en el target group.
## Licencia
MIT. See [MIT License](http://opensource.org/licenses/MIT).
