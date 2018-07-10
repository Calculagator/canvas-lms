#!/bin/bash

set -e

# shellcheck disable=1004
echo '
  ________  ________  ________   ___      ___ ________  ________
|\   ____\|\   __  \|\   ___  \|\  \    /  /|\   __  \|\   ____\
\ \  \___|\ \  \|\  \ \  \\ \  \ \  \  /  / | \  \|\  \ \  \___|_
 \ \  \    \ \   __  \ \  \\ \  \ \  \/  / / \ \   __  \ \_____  \
  \ \  \____\ \  \ \  \ \  \\ \  \ \    / /   \ \  \ \  \|____|\  \
   \ \_______\ \__\ \__\ \__\\ \__\ \__/ /     \ \__\ \__\____\_\  \
    \|_______|\|__|\|__|\|__| \|__|\|__|/       \|__|\|__|\_________\
                                                         \|_________|

Welcome! This script set up an ubuntu 18.04 server to run canvas with docker

When you git pull new changes, you can run this script again to bring
everything up to date.'

if [[ "$USER" == 'root' ]]; then
  echo 'Please do not run this script as root!'
  echo "I'll ask for your sudo password if I need it."
  exit 1
fi

OS="$(uname)"


function installed {
  type "$@" &> /dev/null
}

install='sudo apt-get update && sudo apt-get install -y'
dependencies='git apt-transport-https ca-certificates curl software-properties-common docker-ce'

BOLD="$(tput bold)"
NORMAL="$(tput sgr0)"

function message {
  echo ''
  echo "$BOLD> $*$NORMAL"
}

function prompt {
  read -r -p "$1 " "$2"
}

function confirm_command {
  prompt "OK to run '$*'? [y/n]" confirm
  [[ ${confirm:-n} == 'y' ]] || return 1
  eval "$*"
}

function install_dependencies {
  local packages=()
  for package in $dependencies; do
    installed "$package" || packages+=("$package")
  done
  [[ ${#packages[@]} -gt 0 ]] || return 0

# may need some if in case this script is run a second time with this stuff already installed
  
  message "Get and install official Docker repository GPG key"
  confirm_command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -"
  message "Add Docker Repository"
  confirm_command "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu  $(lsb_release -cs) stable\""
  message "Install dependencies."
  confirm_command "$install ${packages[*]}"
  message "Install docker-compose from github"
  confirm_command "sudo curl -L https://github.com/docker/compose/releases/download/1.21.2/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose"

}
function get_canvas {
  if [ ! -d "canvas" ]; then
  git clone https://github.com/instructure/canvas-lms.git canvas
  fi
  cd canvas
  git checkout stable
  #need a functioning Gemfile.lock
  touch Gemfile.lock
}

function start_docker_daemon {
  service docker status &> /dev/null && return 0
  prompt 'The docker daemon is not running. Start it? [y/n]' confirm
  [[ ${confirm:-n} == 'y' ]] || return 1
  sudo service docker start
  sleep 1 # wait for docker daemon to start
}

function setup_docker_as_nonroot {
  docker ps &> /dev/null && return 0
  message 'Setting up docker for nonroot user...'

  if ! id -Gn "$USER" | grep -q '\bdocker\b'; then
    message "Adding $USER user to docker group..."
    confirm_command "sudo usermod -aG docker $USER" || true
  fi

  message 'We need to login again to apply that change.'
  confirm_command "exec sg docker -c $0"
}

function setup_docker_environment {
  
    start_docker_daemon
    setup_docker_as_nonroot
}

function copy_canvas_config {
  message 'Creating Canvas docker configuration...'
 
#cache_store.yml
echo "production:
  cache_store: redis_store
development:
  cache_store: redis_store" > config/cache_store.yml

#database.yml
echo "common: &common
  adapter: postgresql
  host: postgres
  encoding: utf8
  username: postgres
  timeout: 5000
  prepared_statements: false

production: &production
  <<: *common
  database: canvas
  open: true

development:
  <<: *production

test:
  <<: *common
  database: canvas_test_rails3_<%= ENV['TEST_ENV_NUMBER'] %>
  shard1: canvas_test_rails3_shard1
  shard2: canvas_test_rails3_shard2
  test_shard_1: canvas_test_rails3_shard1
  test_shard_2: canvas_test_rails3_shard2
" > config/database.yml

#domain.yml
message "Don't forget to set the correct domain here in the script"
echo "production:
  domain: canvas.thelatinschool.org

test:
  domain: localhost

development:
  domain: canvas.docker" > config/domain.yml
  
#dynamic_settings.yml
echo "# this config file is useful if you don't want to run a consul
# cluster with canvas.  Just provide the config data you would
# like for the DynamicSettings class to find, and it will use
# it whenever a call for consul data is issued. Data should be
# shaped like the example below, one key for the related set of data,
# and a hash of key/value pairs (no nesting)
production:
  # tree
  config:
    # service
    canvas:
      # prefix
     # address-book:
    #    app-host: http://address-book
     #   secret: opensesame
      canvas:
        encryption-secret: $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
        signing-secret: $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    #  live-events:
    #    aws_endpoint: http://kinesis
    #    kinesis_stream_name: live-events
    #  live-events-subscription-service:
    #    app-host: http://les
    #    sad-panda: null
      math-man:
        base_url: 'http://mathman'
        use_for_svg: 'true'
        use_for_mml: 'true'
    #  rich-content-service:
    #    app-host: rce
    # another service
    #inst-fs:
    #  app-host: http://api.instfs
      # this is just super-sekret-value, base64-encoded:
    #  secret: c3VwZXItc2VrcmV0LXZhbHVlCg==
    #pandata:
    #  ios-pandata-key: IOS_pandata_key
    #  ios-pandata-secret: teamrocketblastoffatthespeedoflight
    #  android-pandata-key: ANDROID_pandata_key
    #  android-pandata-secret: surrendernoworpreparetofight
" > config/dynamic_settings.yml

#outgoing mail
echo "production: &production
  address: mailrelay
  port: 25
  domain: canvas.thelatinschool.org
  outgoing_address: canvas@thelatinschool.org
  default_name: HLS Grades

development:
  <<: *production" > config/outgoing_mail.yml
  
#redis.yml
echo "production:
  servers:
    - redis://redis

development:
  servers:
    - redis://redis

test:
  # only tests that are exercising the integration with redis require redis to run.
  servers:
    - redis://redis
  # warning: the redis database will get cleared before each test, so if you
  # use this server for anything else, make sure to set aside a database id for
  # these tests to use.
  database: 1" > redis.yml
  
#security
echo "production: &default
  encryption_key: <%= ENV[\"ENCRYPTION_KEY\"] %>

development:
  <<: *default

test:
  <<: *default" > config/security.yml
  
}

function copy_docker_config {

echo '# See doc/docker/README.md or https://github.com/instructure/canvas-lms/tree/master/doc/docker
FROM instructure/ruby-passenger:2.5

ENV APP_HOME /usr/src/app/
ENV RAILS_ENV "production"
ENV NGINX_MAX_UPLOAD_SIZE 10g
ENV YARN_VERSION 1.7.0-1

# Work around github.com/zertosh/v8-compile-cache/issues/2
# This can be removed once yarn pushes a release including the fixed version
# of v8-compile-cache.
ENV DISABLE_V8_COMPILE_CACHE 1

USER root
WORKDIR /root
RUN curl -sL https://deb.nodesource.com/setup_8.x | bash - \
  && curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
  && echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list \
  && printf '\''path-exclude /usr/share/doc/*\npath-exclude /usr/share/man/*'\'' > /etc/dpkg/dpkg.cfg.d/01_nodoc \
  && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && apt-get update -qq \
  && apt-get install -qqy --no-install-recommends \
       nodejs \
       yarn="$YARN_VERSION" \
       libxmlsec1-dev \
       python-lxml \
       libicu-dev \
       postgresql-client-10 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /home/docker/.gem/ruby/$RUBY_MAJOR.0

#What if we keep the installed version of bundler from the upstream image?
#RUN if [ -e /var/lib/gems/$RUBY_MAJOR.0/gems/bundler-* ]; then BUNDLER_INSTALL="-i /var/lib/gems/$RUBY_MAJOR.0"; fi \
#  && gem uninstall --all --ignore-dependencies --force $BUNDLER_INSTALL bundler \
#  && gem install bundler --no-document -v 1.16.1 \
#  && find $GEM_HOME ! -user docker | xargs chown docker:docker
RUN gem install bundler --no-document

WORKDIR $APP_HOME

COPY . $APP_HOME

#from instructure/dockerfiles documentation
RUN chown -R docker:docker /usr/src/app /home/docker

# optimizing for size here ... get all the dev dependencies so we can
# compile assets, then throw away everything we do not need
#
# the privilege dropping could be slightly less verbose if we ever add
# gosu (here or upstream)
#
# TODO: once we have docker 17.05+ everywhere, do this via multi-stage
# build

#set user as in non-production
USER docker
RUN bash -c '\'' \
  # bash cuz better globbing and comments \
  set -e; \
  \
  #sudo -u docker -E env HOME=/home/docker PATH=$PATH \
  bundle install --path vendor/bundle --jobs 8; \
  yarn install --prod #--pure-lockfile; \
#  COMPILE_ASSETS_NPM_INSTALL=0 \
  bundle exec rake canvas:compile_assets; \
  \
  # downgrade to prod dependencies \
  #sudo -u docker -E env HOME=/home/docker PATH=$PATH \
  bundle install --path vendor/bundle --without test development; \
  #sudo -u docker -E env HOME=/home/docker PATH=$PATH \
  bundle clean --force; \
  yarn install --prod '\''
  
  
  # now some cleanup... 
  USER root
  RUN bash -c '\'' \
  rm -rf \
    /home/docker/.bundle/cache \
    $GEM_HOME/cache \
    $GEM_HOME/bundler/gems/*/{.git,spec,test,features} \
    $GEM_HOME/gems/*/{spec,test,features} \
    `yarn cache dir` \
    /root/.node-gyp \
    /tmp/phantomjs \
    .yardoc \
    client_apps/canvas_quizzes/{tmp,node_modules} \
    config/locales/generated \
    gems/*/node_modules \
    gems/plugins/*/node_modules \
    log \
    public/dist/maps \
    public/doc/api/*.json \
    public/javascripts/translations \
    tmp-*.tmp'\''

USER docker' > Dockerfile-hls

echo '# See doc/docker/README.md or https://github.com/instructure/canvas-lms/tree/master/doc/docker
version: '\''2'\''
services:
  nginx-proxy:
    image: jwilder/nginx-proxy:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/nginx/vhost.d
      - /usr/share/nginx/html
      - /etc/nginx/certs
      - /var/run/docker.sock:/tmp/docker.sock:ro
  web:
    image: canvas-base
    build:
    #This pulls the Dockerfile from the current directory    
      context: .
      dockerfile: Dockerfile-hls
    volumes:
      - .:/usr/src/app
      - api_docs:/usr/src/app/public/doc/api
      - brandable_css_brands:/usr/src/app/app/stylesheets/brandable_css_brands
      - bundler:/home/docker/.bundler/
      - canvas-docker-gems:/home/docker/.gem/
      - canvas-planner_node_modules:/usr/src/app/packages/canvas-planner/node_modules
      - canvas-planner_lib:/usr/src/app/packages/canvas-planner/lib
      - generated_1:/usr/src/app/public/javascripts/client_apps
      - generated_2:/usr/src/app/public/dist
      - generated_3:/usr/src/app/public/javascripts/compiled
      - i18nliner_node_modules:/usr/src/app/gems/canvas_i18nliner/node_modules
      - locales:/usr/src/app/config/locales/generated
      - /usr/src/app/log
      - production_gems:/vendor/bundle
      - node_modules:/usr/src/app/node_modules
      - quizzes_dist:/usr/src/app/client_apps/canvas_quizzes/dist
      - quizzes_node_modules:/usr/src/app/client_apps/canvas_quizzes/node_modules
      - quizzes_tmp:/usr/src/app/client_apps/canvas_quizzes/tmp
      - selinimum_node_modules:/usr/src/app/gems/selinimum/node_modules
      - styleguide:/usr/src/app/app/views/info
      - tmp:/usr/src/app/tmp
      - translations:/usr/src/app/public/javascripts/translations
      - yardoc:/usr/src/app/.yardoc
      - yarn-cache:/home/docker/.cache/yarn
    environment:
      RAILS_ENV: production
      ENCRYPTION_KEY: $THK@h1Pwl%N26JqiIANau%JQNYPxVDk  
      VIRTUAL_HOST: canvas.thelatinschool.org
      LESTENCRYPT_HOST: canvas.thelatinschool.org
      LETSENCRYPT_EMAIL: it@thelatinschool.org
    links:
      - postgres
      - redis
#      - attendance
#      - mathman
#      - mailrelay

  jobs:
    image: canvas-base
    volumes_from:
      - web
    environment: 
      RAILS_ENV: production
      ENCRYPTION_KEY: $THK@h1Pwl%N26JqiIANau%JQNYPxVDk
    command: bundle exec script/delayed_job run
    links:
      - postgres
      - redis
  webpack:
    image: canvas-base
    volumes_from:
      - web
    environment: 
      RAILS_ENV: production
      ENCRYPTION_KEY: $THK@h1Pwl%N26JqiIANau%JQNYPxVDk
    command: yarn run webpack
  postgres:
 #Different Dockerfile from subdirectory-
 #I think this could be replaced by a standard image just like the production instructions use 
  #  build: ./docker-compose/postgres
    image: postgres:10-alpine
    volumes:
      - pg_data:/var/lib/postgresql/data
  redis:
    image: redis:alpine
  letsencrypt-nginx-proxy-companion:
    image: jrcs/letsencrypt-nginx-proxy-companion
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    volumes_from:
      - nginx-proxy

volumes:
  api_docs: {}
  brandable_css_brands: {}
  bundler: {}
  canvas-docker-gems: {}
  canvas-planner_node_modules: {}
  canvas-planner_lib: {}
  generated_1: {}
  generated_2: {}
  generated_3: {}
  i18nliner_node_modules: {}
  locales: {}
  log: {}
  node_modules: {}
  pg_data: {}
  production_gems: {}
  quizzes_dist: {}
  quizzes_node_modules: {}
  quizzes_tmp: {}
  selinimum_node_modules: {}
  styleguide: {}
  tmp: {}
  translations: {}
  yardoc: {}
  yarn-cache: {} ' > docker-compose.hls.yml
}

function build_images {
  message 'Building docker images...'
  docker-compose -f docker-compose.hls.yml build
}

function install_gems {
  message 'Installing gems...'

  if [[ -e Gemfile.lock ]]; then
    message \
'For historical reasons, the Canvas Gemfile.lock is not tracked by git. We may
need to remove it before we can install gems, to prevent conflicting depencency
errors.'
    confirm_command 'rm Gemfile.lock' || true
  fi

  # Fixes 'error while trying to write to `/usr/src/app/Gemfile.lock`'
  if ! docker-compose run --rm web touch Gemfile.lock; then
    message \
"The 'docker' user is not allowed to write to Gemfile.lock. We need write
permissions so we can install gems."
    touch Gemfile.lock
    confirm_command 'chmod a+rw Gemfile.lock' || true
  fi

#Seems redundant since this command gets run @ image creation by docker
message "*************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************************"
  docker-compose run --no-deps --rm web bundle install --path /vendor/bundle
}

function database_exists {
  docker-compose -f docker-compose.hls.yml run --rm web \
    bundle exec rails runner 'ActiveRecord::Base.connection' &> /dev/null
}

function prepare_database {
  message 'Setting up the database...'

  if ! docker-compose -f docker-compose.hls.yml run --rm web touch db/structure.sql; then
    message \
"The 'docker' user is not allowed to write to db/structure.sql. We need write
permissions so we can run migrations."
    touch db/structure.sql
    confirm_command 'chmod a+rw db/structure.sql' || true
  fi

  if database_exists; then
    message 'Database exists. Migrating...'
    docker-compose -f docker-compose.hls.yml run --rm web bundle exec rake db:migrate
  else
    message 'Database does not exist. Running initial setup...'
    docker-compose -f docker-compose.hls.yml run --rm web bundle exec rake db:create db:migrate db:initial_setup
  fi

#  message 'Setting up the test database...'
#  docker-compose run -f docker-compose.hls.yml --rm web bundle exec rake db:create db:migrate RAILS_ENV=production
}

function compile_assets {
  message 'Compiling assets...'
  docker-compose -f docker-compose.hls.yml run --rm web bundle exec rake \
    canvas:compile_assets \
    brand_configs:generate_and_upload_all
}

function setup_canvas {
  message 'Now we can set up Canvas!'
  get_canvas
  copy_canvas_config
  copy_docker_config
  build_images
#  install_gems
  prepare_database
  compile_assets
}

function display_next_steps {
  message "You're good to go! Next steps:"

  # shellcheck disable=SC2016
  [[ $OS == 'Linux' ]] && echo '
  I have added your user to the docker group so you can run docker commands
  without sudo. Note that this has security implications:

  https://docs.docker.com/engine/installation/linux/linux-postinstall/

  You may need to logout and login again for this to take effect.'

  echo "
  Running Canvas:

    docker-compose -f docker-compose.hls.yml up -d
    open http://canvas.docker

    I'm stuck. Where can I go for help?

    FAQ:           https://github.com/instructure/canvas-lms/wiki/FAQ
    Dev & Friends: http://instructure.github.io/
    Canvas Guides: https://guides.instructure.com/
    Vimeo channel: https://vimeo.com/canvaslms
    API docs:      https://canvas.instructure.com/doc/api/index.html
    Mailing list:  http://groups.google.com/group/canvas-lms-users
    IRC:           http://webchat.freenode.net/?channels=canvas-lms

    Please do not open a GitHub issue until you have tried asking for help on
    the mailing list or IRC - GitHub issues are for verified bugs only.
    Thanks and good luck!
  "
}

setup_docker_environment
setup_canvas
display_next_steps
