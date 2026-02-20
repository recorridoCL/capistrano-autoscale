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
set :instance_order, 'even'          # default; puede ser 'odd' para la otra mitad
set :blue_green_min_instances, 2     # default; mínimo para habilitar blue/green
set :blue_green_orders, %w[even odd] # default; secuencia de waves; puedes cambiarla
set :blue_green_create_ami, true     # default; si quieres crear AMI al final del blue/green
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
- La paridad `even/odd` se aplica por índice del listado ordenado, comenzando en 0.

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
El wrapper detecta que no hay instancias suficientes y ejecuta `deploy` normal.

### Blue/green por paridad
Con 2 o más instances en el target group, el wrapper:
1) Cuenta instances del target group.
2) Si hay suficientes, corre waves en secuencia (`blue_green_orders`, default `even` luego `odd`), pasando `INSTANCE_ORDER` a cada wave. Entre cada wave, va deregistrando/registrando las instancias correspondientes.
3) Al finalizar las waves, opcionalmente ejecuta `deploy:new_ami_configuration` (controlado por `blue_green_create_ami`).

Puedes forzar el orden en runtime:
```bash
INSTANCE_ORDER=odd bundle exec cap production deploy
```
(Por si quieres correr sólo una wave manualmente.)

## Tareas incluidas

- `autoscaled:deploy`: wrapper que decide normal vs. blue/green según el conteo del target group.
- `autoscaled:blue_green_deploy`: ejecuta las waves en el orden configurado y luego la creación de AMI opcional.
- `deploy:register_instances_in_load_balancer`: registra los `:instances` actuales en el target group.
- `deploy:deregister_instances_from_load_balancer`: los saca del target group.
- `deploy:new_ami_configuration`: crea AMI desde una instance del ASG, genera nueva versión del Launch Template y la deja como default (requiere `:volume_sizes`, `:instance_type`, `:autoscaling_group_name`).

## Casos especiales
- **Una sola instance**: usa `instance_order = 'even'` (default) para incluir el índice 0; el wrapper hará deploy normal (sin waves ni deregistro/registro).
- **Instance extra fuera del ASG (cron/sidekiq) pero en el target group**: se incluye en el conteo y en las waves porque el discovery se basa en el target group.
- **Orden de waves**: cambia `blue_green_orders` (ej. `%w[even odd]` o sólo `%w[even]` si quieres evitar un segundo wave en single-node).

## Licencia
MIT. See [MIT License](http://opensource.org/licenses/MIT).
