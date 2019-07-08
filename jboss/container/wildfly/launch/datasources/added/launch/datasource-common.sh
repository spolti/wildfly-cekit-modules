#!/bin/sh

if [ -n "${TEST_LAUNCH_INCLUDE}" ]; then
    source "${TEST_LAUNCH_INCLUDE}"
else
    source $JBOSS_HOME/bin/launch/launch-common.sh
fi

if [ -n "${TEST_TX_DATASOURCE_INCLUDE}" ]; then
    source "${TEST_TX_DATASOURCE_INCLUDE}"
else
    source $JBOSS_HOME/bin/launch/tx-datasource.sh
fi

if [ -n "${TEST_LOGGING_INCLUDE}" ]; then
    source "${TEST_LOGGING_INCLUDE}"
else
    source $JBOSS_HOME/bin/launch/logging.sh
fi

function getDataSourceConfigureMode() {
  # THe extra +x makes this check whether the variable is unset, as '' is a valid value
  if [ -z ${DS_CONFIGURE_MODE+x} ]; then
    getConfigurationMode "<!-- ##DATASOURCES## -->" "DS_CONFIGURE_MODE"
  fi

  printf -v "$1" '%s' "${DS_CONFIGURE_MODE}"
}

function clearDatasourceEnv() {
  local prefix=$1
  local service=$2

  unset ${service}_HOST
  unset ${service}_PORT
  unset ${prefix}_JNDI
  unset ${prefix}_USERNAME
  unset ${prefix}_PASSWORD
  unset ${prefix}_DATABASE
  unset ${prefix}_TX_ISOLATION
  unset ${prefix}_MIN_POOL_SIZE
  unset ${prefix}_MAX_POOL_SIZE
  unset ${prefix}_JTA
  unset ${prefix}_NONXA
  unset ${prefix}_DRIVER
  unset ${prefix}_CONNECTION_CHECKER
  unset ${prefix}_EXCEPTION_SORTER
  unset ${prefix}_URL
  unset ${prefix}_BACKGROUND_VALIDATION
  unset ${prefix}_BACKGROUND_VALIDATION_MILLIS

  for xa_prop in $(compgen -v | grep -s "${prefix}_XA_CONNECTION_PROPERTY_"); do
    unset ${xa_prop}
  done
}

function clearDatasourcesEnv() {
  IFS=',' read -a db_backends <<< $DB_SERVICE_PREFIX_MAPPING
  for db_backend in "${db_backends[@]}"; do
    service_name=${db_backend%=*}
    service=${service_name^^}
    service=${service//-/_}
    db=${service##*_}
    prefix=${db_backend#*=}

    clearDatasourceEnv $prefix $service
  done

  unset TIMER_SERVICE_DATA_STORE

  for datasource_prefix in $(echo $DATASOURCES | sed "s/,/ /g"); do
    clearDatasourceEnv $datasource_prefix $datasource_prefix
  done
  unset DATASOURCES
  unset JDBC_STORE_JNDI_NAME
  unset DS_CONFIGURE_MODE
}

# Finds the name of the database services and generates data sources
# based on this info
function inject_datasources_common() {

  inject_internal_datasources

  tx_datasource="$(inject_tx_datasource)"
  if [ -n "$tx_datasource" ]; then
    local dsConfMode
    getDataSourceConfigureMode "dsConfMode"
    if [ "${dsConfMode}" = "xml" ]; then
      sed -i "s|<!-- ##DATASOURCES## -->|${tx_datasource}<!-- ##DATASOURCES## -->|" $CONFIG_FILE
    elif [ "${dsConfMode}" = "cli" ]; then
      echo "${tx_datasource}" >> ${CLI_SCRIPT_FILE}
    fi

  fi

  inject_external_datasources
}

function inject_internal_datasources() {

  # keep this from polluting other scripts
  local jndi

  # Find all databases in the $DB_SERVICE_PREFIX_MAPPING separated by ","
  IFS=',' read -a db_backends <<< $DB_SERVICE_PREFIX_MAPPING

  if [ -z "$TIMER_SERVICE_DATA_STORE" ]; then
    inject_default_timer_service
  fi

  if [ "${#db_backends[@]}" -eq "0" ]; then
    datasource=$(generate_datasource)
    if [ -n "$datasource" ]; then
      local dsConfMode
      getDataSourceConfigureMode "dsConfMode"
      if [ "${dsConfMode}" = "xml" ]; then
        sed -i "s|<!-- ##DATASOURCES## -->|${datasource}<!-- ##DATASOURCES## -->|" $CONFIG_FILE
      elif [ "${dsConfMode}" = "cli" ]; then
        echo "${datasource}" >> ${CLI_SCRIPT_FILE}
      fi
    fi

    if [ -z "$defaultDatasourceJndi" ] && [ -n "${ENABLE_GENERATE_DEFAULT_DATASOURCE}" ] && [ "${ENABLE_GENERATE_DEFAULT_DATASOURCE^^}" = "TRUE" ]; then
      defaultDatasourceJndi="java:jboss/datasources/ExampleDS"
    fi
  else
    for db_backend in "${db_backends[@]}"; do

      local service_name=${db_backend%=*}
      local service=${service_name^^}
      service=${service//-/_}
      local db=${service##*_}
      local prefix=${db_backend#*=}

      if [[ "$service" != *"_"* ]]; then
        log_warning "There is a problem with the DB_SERVICE_PREFIX_MAPPING environment variable!"
        log_warning "You provided the following database mapping (via DB_SERVICE_PREFIX_MAPPING): $db_backend. The mapping does not contain the database type."
        log_warning
        log_warning "Please make sure the mapping is of the form <name>-<database_type>=PREFIX, where <database_type> is either MYSQL or POSTGRESQL."
        log_warning
        log_warning "The datasource for $prefix service WILL NOT be configured."
        continue
      fi

      inject_datasource $prefix $service $service_name

      if [ -z "$defaultDatasourceJndi" ]; then
        # make sure we re-read $jndi, messaging uses it too
        jndi=$(get_jndi_name "$prefix" "$service")
        defaultDatasourceJndi="$jndi"
      fi
    done
  fi

  writeEEDefaultDatasource
}

function writeEEDefaultDatasource() {
  # Check the override and use that instead of the 'guess' if set
  local forcedDefaultEeDs="false"
  if [ -n "${defaultDatasourceJndi}" ] && [ -z "${EE_DEFAULT_DS_JNDI_NAME+x}" ]; then
    log_warning "The default datasource for the ee subsystem has been guessed to be ${defaultDatasourceJndi}. Specify this using EE_DEFAULT_DS_JNDI_NAME"
  fi
  if [ ! -z "${EE_DEFAULT_DS_JNDI_NAME+x}" ]; then
    defaultDatasourceJndi="${EE_DEFAULT_DS_JNDI_NAME}"
    forcedDefaultEeDs="true"
  fi

  # Set the default datasource
  local defaultEEDatasourceConfMode
  getConfigurationMode "<!-- ##DEFAULT_DATASOURCE## -->" "defaultEEDatasourceConfMode"
  if [ "${defaultEEDatasourceConfMode}" = "xml" ]; then
    writeEEDefaultDatasourceXml
  elif [ "${defaultEEDatasourceConfMode}" = "cli" ]; then
    writeEEDefaultDatasourceCli
  fi
}

function writeEEDefaultDatasourceXml() {
  if [ -n "$defaultDatasourceJndi" ]; then
    defaultDatasource="datasource=\"$defaultDatasourceJndi\""
  else
    defaultDatasource=""
  fi
  # new format replacement : datasource="##DEFAULT_DATASOURCE##"
  sed -i "s|datasource=\"##DEFAULT_DATASOURCE##\"|${defaultDatasource}|" $CONFIG_FILE
  # old format (for compat)
  sed -i "s|<!-- ##DEFAULT_DATASOURCE## -->|${defaultDatasource}|" $CONFIG_FILE
}

function writeEEDefaultDatasourceCli() {

  local xpath="\"//*[local-name()='subsystem' and starts-with(namespace-uri(), 'urn:jboss:domain:ee:')]\""
  local ret
  testXpathExpression "${xpath}" "ret"
  if [ $ret -ne 0 ]; then
    if [ "${forcedDefaultEeDs}" = "true" ]; then
      echo "EE_DEFAULT_DS_JNDI_NAME was set to \'${EE_DEFAULT_DS_JNDI_NAME}\' but the configuration contains no ee subsystem"
      exit 1
    else
      # We have no ee subsystem and have just guessed what should go in - this is fine
      return
    fi
  fi

  local resource="/subsystem=ee/service=default-bindings"
  # Add the default bindings if not there
  echo "
    if (outcome != success) of $resource:read-resource
      $resource:add
    end-if
  " >> ${CLI_SCRIPT_FILE}


  xpath="\"//*[local-name()='subsystem' and starts-with(namespace-uri(), 'urn:jboss:domain:ee:')]/@datasource\""
  ret=""
  testXpathExpression "${xpath}" "ret"
  local writeDs="$resource:write-attribute(name=datasource, value=${defaultDatasourceJndi})"
  local undefineDs="$resource:undefine-attribute(name=datasource)"
  local cli_action
  if [ $ret -eq 0 ]; then
    # Attribute exists in config already
    if [ "${forcedDefaultEeDs}" = true ]; then
      # We forced it, so override with whatever the value of EE_DEFAULT_DS_JNDI_NAME was
      if [ -n "${defaultDatasourceJndi}" ]; then
        cli_action="${writeDs}"
      else
        cli_action="${undefineDs}"
      fi
    fi
  else
    # Attribute does not exist in config already, so write whatever was defined
    if [ -n "${defaultDatasourceJndi}" ]; then
      cli_action="${writeDs}"
    fi
  fi

  if [ -n "${cli_action}" ]; then
    echo "
        ${cli_action}
      " >> ${CLI_SCRIPT_FILE}
  fi
}

function inject_external_datasources() {
  # Add extensions from envs
  if [ -n "$DATASOURCES" ]; then
    for datasource_prefix in $(echo $DATASOURCES | sed "s/,/ /g"); do
      inject_datasource $datasource_prefix $datasource_prefix $datasource_prefix
    done
  fi
}

# Arguments:
# $1 - service name
# $2 - datasource jndi name
# $3 - datasource username
# $4 - datasource password
# $5 - datasource host
# $6 - datasource port
# $7 - datasource databasename
# $8 - connection checker class
# $9 - exception sorter class
# $10 - driver
# $11 - original service name
# $12 - datasource jta
# $13 - validate
# $14 - url
function generate_datasource_common() {
  local pool_name="${1}"
  local jndi_name="${2}"
  local username="${3}"
  local password="${4}"
  local host="${5}"
  local port="${6}"
  local databasename="${7}"
  local checker="${8}"
  local sorter="${9}"
  local driver="${10}"
  local service_name="${11}"
  local jta="${12}"
  local validate="${13}"
  local url="${14}"

  local dsConfMode
  getDataSourceConfigureMode "dsConfMode"
  if [ "${dsConfMode}" = "xml" ]; then
    # CLOUD-3198 Since Sed replaces '&' with a full match, we need to escape it.
    local url="${14//&/\\&}"
    # CLOUD-3198 In addition to that, we also need to escape ';'
    url="${url//;/\\;}"
  fi

  if [ -n "$driver" ]; then
    ds=$(generate_external_datasource)
  else
    jndi_name="java:jboss/datasources/ExampleDS"
    if [ -n "$DB_JNDI" ]; then
      jndi_name="$DB_JNDI"
    fi
    pool_name="ExampleDS"
    if [ -n "$DB_POOL" ]; then
      pool_name="$DB_POOL"
    fi

    # Scripts that want to enable addition of the default data source should set
    # ENABLE_GENERATE_DEFAULT_DATASOURCE=true
    if [ -n "${ENABLE_GENERATE_DEFAULT_DATASOURCE}" ] && [ "${ENABLE_GENERATE_DEFAULT_DATASOURCE^^}" = "TRUE" ]; then
      ds=$(generate_default_datasource)
    fi
  fi

  if [ -z "$service_name" ]; then
    if [ -n "${ENABLE_GENERATE_DEFAULT_DATASOURCE}" ] && [ "${ENABLE_GENERATE_DEFAULT_DATASOURCE^^}" = "TRUE" ]; then
      service_name="ExampleDS"
      driver="hsql"
    else
      return
    fi
  fi

  if [ -n "$TIMER_SERVICE_DATA_STORE" -a "$TIMER_SERVICE_DATA_STORE" = "${service_name}" ]; then
    inject_timer_service ${pool_name} ${jndi_name} ${driver} ${TIMER_SERVICE_DATA_STORE_REFRESH_INTERVAL:--1}
  fi

  if [ "${dsConfMode}" = "xml" ]; then
    # Only do this replacement if we are replacing an xml marker
    echo "$ds" | sed ':a;N;$!ba;s|\n|\\n|g'
  elif [ "${dsConfMode}" = "cli" ]; then
    # If using cli, return the raw string, preserving line breaks
    echo "$ds"
  fi
}

function generate_external_datasource() {
  local dsConfMode
  getDataSourceConfigureMode "dsConfMode"
  if [ "${dsConfMode}" = "xml" ]; then
    echo "$(generate_external_datasource_xml)"
  elif [ "${dsConfMode}" = "cli" ]; then
    echo "$(generate_external_datasource_cli)"
  fi
}

function generate_external_datasource_xml() {
  local failed="false"

  if [ -n "$NON_XA_DATASOURCE" ] && [ "$NON_XA_DATASOURCE" = "true" ]; then
    ds="<datasource jta=\"${jta}\" jndi-name=\"${jndi_name}\" pool-name=\"${pool_name}\" enabled=\"true\" use-java-context=\"true\" statistics-enabled=\"\${wildfly.datasources.statistics-enabled:\${wildfly.statistics-enabled:false}}\">
          <connection-url>${url}</connection-url>
          <driver>$driver</driver>"
  else
    ds=" <xa-datasource jndi-name=\"${jndi_name}\" pool-name=\"${pool_name}\" enabled=\"true\" use-java-context=\"true\" statistics-enabled=\"\${wildfly.datasources.statistics-enabled:\${wildfly.statistics-enabled:false}}\">"
    local xa_props=$(compgen -v | grep -s "${prefix}_XA_CONNECTION_PROPERTY_")
    if [ -z "$xa_props" ]; then
      log_warning "At least one ${prefix}_XA_CONNECTION_PROPERTY_property for datasource ${service_name} is required. Datasource will not be configured."
      failed="true"
    else

      for xa_prop in $(echo $xa_props); do
        prop_name=$(echo "${xa_prop}" | sed -e "s/${prefix}_XA_CONNECTION_PROPERTY_//g")
        prop_val=$(find_env $xa_prop)
        if [ ! -z ${prop_val} ]; then
          ds="$ds <xa-datasource-property name=\"${prop_name}\">${prop_val}</xa-datasource-property>"
        fi
      done

      ds="$ds
             <driver>${driver}</driver>"
    fi

    if [ -n "$tx_isolation" ]; then
      ds="$ds
             <transaction-isolation>$tx_isolation</transaction-isolation>"
    fi
  fi

  if [ -n "$min_pool_size" ] || [ -n "$max_pool_size" ]; then
    if [ -n "$NON_XA_DATASOURCE" ] && [ "$NON_XA_DATASOURCE" = "true" ]; then
       ds="$ds
             <pool>"
    else
      ds="$ds
             <xa-pool>"
    fi

    if [ -n "$min_pool_size" ]; then
      ds="$ds
             <min-pool-size>$min_pool_size</min-pool-size>"
    fi
    if [ -n "$max_pool_size" ]; then
      ds="$ds
             <max-pool-size>$max_pool_size</max-pool-size>"
    fi
    if [ -n "$NON_XA_DATASOURCE" ] && [ "$NON_XA_DATASOURCE" = "true" ]; then
      ds="$ds
             </pool>"
    else
      ds="$ds
             </xa-pool>"
    fi
  fi

   ds="$ds
         <security>
           <user-name>${username}</user-name>
           <password>${password}</password>
         </security>"

  if [ "$validate" == "true" ]; then

    validation_conf="<validate-on-match>true</validate-on-match>
                       <background-validation>false</background-validation>"

    if [ $(find_env "${prefix}_BACKGROUND_VALIDATION" "false") == "true" ]; then

        millis=$(find_env "${prefix}_BACKGROUND_VALIDATION_MILLIS" 10000)
        validation_conf="<validate-on-match>false</validate-on-match>
                           <background-validation>true</background-validation>
                           <background-validation-millis>${millis}</background-validation-millis>"
    fi

    ds="$ds
           <validation>
             ${validation_conf}
             <valid-connection-checker class-name=\"${checker}\"></valid-connection-checker>
             <exception-sorter class-name=\"${sorter}\"></exception-sorter>
           </validation>"
  fi

  if [ -n "$NON_XA_DATASOURCE" ] && [ "$NON_XA_DATASOURCE" = "true" ]; then
    ds="$ds
           </datasource>"
  else
    ds="$ds
           </xa-datasource>"
  fi

  if [ "$failed" == "true" ]; then
    echo ""
  else
    echo $ds
  fi
}

function generate_external_datasource_cli() {
  local failed="false"

  local subsystem_addr="/subsystem=datasources"
  local ds_resource="${subsystem_addr}"

  local -A ds_tmp_key_values
  ds_tmp_key_values["jndi-name"]=${jndi_name}
  ds_tmp_key_values["enabled"]="true"
  ds_tmp_key_values["use-java-context"]="true"
  ds_tmp_key_values["statistics-enabled"]="\${wildfly.datasources.statistics-enabled:\${wildfly.statistics-enabled:false}}"
  ds_tmp_key_values["driver-name"]="${driver}"

  local -A ds_tmp_xa_connection_properties

  if [ -n "$NON_XA_DATASOURCE" ] && [ "$NON_XA_DATASOURCE" = "true" ]; then
    ds_resource="$ds_resource/data-source=${pool_name}"

    ds_tmp_key_values["jta"]="${jta}"
    ds_tmp_key_values['connection-url']="${url}"

  else
    ds_resource="$ds_resource/xa-data-source=${pool_name}"

        local xa_props=$(compgen -v | grep -s "${prefix}_XA_CONNECTION_PROPERTY_")
    if [ -z "$xa_props" ] && [ "$driver" != "postgresql" ] && [ "$driver" != "mysql" ]; then
      log_warning "At least one ${prefix}_XA_CONNECTION_PROPERTY_property for datasource ${service_name} is required. Datasource will not be configured."
      failed="true"
    else

      for xa_prop in $(echo $xa_props); do
        prop_name=$(echo "${xa_prop}" | sed -e "s/${prefix}_XA_CONNECTION_PROPERTY_//g")
        prop_val=$(find_env $xa_prop)
        if [ ! -z ${prop_val} ]; then
          ds_tmp_xa_connection_properties["$prop_name"]="$prop_val"
        fi
      done

      if [ -n "${tx_isolation}" ]; then
        ds_tmp_key_values["transaction-isolation"]="${tx_isolation}"
      fi
    fi

  fi

  if [ -n "$min_pool_size" ]; then
    ds_tmp_key_values["min-pool-size"]=$min_pool_size
  fi
  if [ -n "$max_pool_size" ]; then
    ds_tmp_key_values["max-pool-size"]=$max_pool_size
  fi

  ds_tmp_key_values["user-name"]="${username}"
  ds_tmp_key_values["password"]="${password}"

  if [ "$validate" == "true" ]; then

    ds_tmp_key_values["validate-on-match"]="true"
    ds_tmp_key_values["background-validation"]="false"

    if [ $(find_env "${prefix}_BACKGROUND_VALIDATION" "false") == "true" ]; then

        millis=$(find_env "${prefix}_BACKGROUND_VALIDATION_MILLIS" 10000)
        ds_tmp_key_values["validate-on-match"]="false"
        ds_tmp_key_values["background-validation"]="true"
        ds_tmp_key_values["background-validation-millis"]="${millis}"
    fi

    ds_tmp_key_values["valid-connection-checker-class-name"]="${checker}"
    ds_tmp_key_values["exception-sorter-class-name"]="${sorter}"
  fi

  ###########################################
  # Construct the CLI part

  # Create the add operation
  local ds_tmp_add="$ds_resource:add("
  local tmp_separator=""
  for key in "${!ds_tmp_key_values[@]}"; do
    ds_tmp_add="${ds_tmp_add}${tmp_separator}${key}=\"${ds_tmp_key_values[$key]}\""
    tmp_separator=", "
  done
  ds_tmp_add="${ds_tmp_add})"

  # Add the xa-ds properties
  local ds_tmp_xa_properties
  for key in "${!ds_tmp_xa_connection_properties[@]}"; do
    ds_tmp_xa_properties="${ds_tmp_xa_properties}
        $ds_resource/xa-datasource-properties=${key}:add(value=\"${ds_tmp_xa_connection_properties[$key]}\")
    "
  done

  # We check if the datasource is there and remove it before re-adding in a batch.
  # Otherwise we simply add it. Unfortunately CLI control flow does not work when wrapped
  # in a batch

  ds="
    if (outcome != success) of $subsystem_addr:read-resource
      echo \"You have set environment variables to configure the datasource \'${pool_name}\'. Fix your configuration to contain a datasources subsystem for this to happen.\"
      exit
    end-if

    if (outcome == success) of $ds_resource:read-resource
      batch
      $ds_resource:remove
      ${ds_tmp_add}
      ${ds_tmp_xa_properties}
      run-batch
    else
      batch
      ${ds_tmp_add}
      ${ds_tmp_xa_properties}
      run-batch
    end-if
  "
  if [ "$failed" == "true" ]; then
    echo ""
  else
    echo "$ds"
  fi
}

function generate_default_datasource() {

  local ds_tmp_url=""

  if [ -n "$url" ]; then
    ds_tmp_url="${url}"
  else
    ds_tmp_url="jdbc:h2:mem:test;DB_CLOSE_DELAY=-1;DB_CLOSE_ON_EXIT=FALSE"
  fi

  local dsConfMode
  getDataSourceConfigureMode "dsConfMode"
  if [ "${dsConfMode}" = "xml" ]; then
    echo "$(generate_default_datasource_xml $ds_tmp_url)"
  elif [ "${dsConfMode}" = "cli" ]; then
    echo "$(generate_default_datasource_cli $ds_tmp_url)"
  fi
}

function generate_default_datasource_xml() {
  local ds_tmp_url=$1

  ds="<datasource jta=\"true\" jndi-name=\"${jndi_name}\" pool-name=\"${pool_name}\" enabled=\"true\" use-java-context=\"true\" statistics-enabled=\"\${wildfly.datasources.statistics-enabled:\${wildfly.statistics-enabled:false}}\">
    <connection-url>${ds_tmp_url}</connection-url>"

  ds="$ds
        <driver>h2</driver>
          <security>
            <user-name>sa</user-name>
            <password>sa</password>
          </security>
        </datasource>"

  echo $ds
}

function generate_default_datasource_cli() {
  local ds_tmp_url=$1

  local ds_resource="/subsystem=datasources/data-source=${pool_name}"

  # Here we assume that if the default DS was created any other way, we don't do anything.
  # All the default ds parameters are hardcoded. So if it already exists, we leave it alone.
  # TODO Double-check the ds_tmp_url parameter, it looks like it is hardcoded too

  ds="
    if (outcome != success) of $ds_resource:read-resource
      $ds_resource:add(jta=true, jndi-name=${jndi_name}, enabled=true, use-java-context=true, statistics-enabled=\${wildfly.datasources.statistics-enabled:\${wildfly.statistics-enabled:false}}, driver-name=h2, user-name=sa, password=sa, connection-url=\"${ds_tmp_url}\")
    end-if
"
  echo "$ds"
}

function inject_default_timer_service() {
  local confMode
  getConfigurationMode "<!-- ##TIMER_SERVICE## -->" "confMode"
  if [ "$confMode" = "xml" ]; then
    local timerservice="            <timer-service thread-pool-name=\"default\" default-data-store=\"default-file-store\">\
                  <data-stores>\
                      <file-data-store name=\"default-file-store\" path=\"timer-service-data\" relative-to=\"jboss.server.data.dir\"/>\
                  </data-stores>\
              </timer-service>"
    sed -i "s|<!-- ##TIMER_SERVICE## -->|${timerservice}|" $CONFIG_FILE
  elif [ "$confMode" = "cli" ]; then
    local hasEjb3Subsystem
    local xpath="\"//*[local-name()='subsystem' and starts-with(namespace-uri(), 'urn:jboss:domain:ejb3:')]\""
    testXpathExpression "${xpath}" "hasEjb3Subsystem"
    if [ $hasEjb3Subsystem -eq 0 ]; then
      # Since we are adding a default, we only do this if we have an ejb3 subsystem
      local timerResource="/subsystem=ejb3/service=timer-service"
      # Only add this if there is no timer service already existing in the config
      local cli="
        if (outcome != success) of ${timerResource}:read-resource
          batch
          ${timerResource}:add(thread-pool-name=default, default-data-store=default-file-store)
          ${timerResource}/file-data-store=default-file-store:add(path=timer-service-data, relative-to=jboss.server.data.dir)
          run-batch
        end-if
      "
      echo "${cli}" >> ${CLI_SCRIPT_FILE}
    fi
  fi
}

# $1 - service/pool name
# $2 - datasource jndi name
# $3 - datasource databasename
# $4 - datastore refresh-interval (only applicable on eap7.x)
function inject_timer_service() {
  local pool_name="${1}"
  local datastore_name="${pool_name}"_ds
  local jndi_name="${2}"
  local databasename="${3}"
  local refresh_interval="${4}"

  local confMode
  getConfigurationMode "<!-- ##TIMER_SERVICE## -->" "confMode"
  if [ "$confMode" = "xml" ]; then
    local timerservice="            <timer-service thread-pool-name=\"default\" default-data-store=\"${datastore_name}\">\
                  <data-stores>\
                    <database-data-store name=\"${datastore_name}\" datasource-jndi-name=\"${jndi_name}\" database=\"${databasename}\" partition=\"${pool_name}_part\" refresh-interval=\"${refresh_interval}\"/>
                  </data-stores>\
              </timer-service>"
    sed -i "s|<!-- ##TIMER_SERVICE## -->|${timerservice}|" $CONFIG_FILE
  elif [ "$confMode" = "cli" ]; then
    local hasEjb3Subsystem
    local xpath="\"//*[local-name()='subsystem' and starts-with(namespace-uri(), 'urn:jboss:domain:ejb3:')]\""
    testXpathExpression "${xpath}" "hasEjb3Subsystem"
    if [ $hasEjb3Subsystem -ne 0 ]; then
      # No ejb3 subsystem is an error
      echo "You have set the TIMER_SERVICE_DATA_STORE environment variable which adds a timer-service to the ejb3 subsystem. Fix your configuration to contain an ejb3 subsystem for this to happen."
      exit 1
    else
      local timerResource="/subsystem=ejb3/service=timer-service"
      local datastoreResource="${timerResource}/database-data-store=${datastore_name}"
      local datastoreAdd="
        ${datastoreResource}:add(datasource-jndi-name=${jndi_name}, database=${databasename}, partition=${pool_name}_part, refresh-interval=${refresh_interval})"
      # We add the timer-service and the datastore in a batch if it is not there
      local cli="
        if (outcome != success) of ${timerResource}:read-resource
          batch
          ${timerResource}:add(thread-pool-name=default, default-data-store=${datastore_name})
          ${datastoreAdd}
          run-batch
        end-if"
      # Next we add the datastore if not there. This will work both if we added it in the previous line, or if the
      # user supplied a configuration that already contained the timer service but not the desired datastore
      cli="${cli}
        if (outcome != success) of ${datastoreResource}:read-resource
          ${datastoreAdd}
        end-if"
      #Finally we write the default-data-store attribute, which should work whether we added the
      #timer-service or the datastore or not
      cli="${cli}
        ${timerResource}:write-attribute(name=default-data-store, value=${datastore_name})
      "
      echo "${cli}" >> ${CLI_SCRIPT_FILE}
    fi
  fi
}

function inject_datasource() {
  local prefix=$1
  local service=$2
  local service_name=$3

  local host
  local port
  local jndi
  local username
  local password
  local database
  local tx_isolation
  local min_pool_size
  local max_pool_size
  local jta
  local NON_XA_DATASOURCE
  local driver
  local validate
  local checker
  local sorter
  local url
  local service_name

  host=$(find_env "${service}_SERVICE_HOST")

  port=$(find_env "${service}_SERVICE_PORT")

  # Custom JNDI environment variable name format: [NAME]_[DATABASE_TYPE]_JNDI
  jndi=$(get_jndi_name "$prefix" "$service")

  # Database username environment variable name format: [NAME]_[DATABASE_TYPE]_USERNAME
  username=$(find_env "${prefix}_USERNAME")

  # Database password environment variable name format: [NAME]_[DATABASE_TYPE]_PASSWORD
  password=$(find_env "${prefix}_PASSWORD")

  # Database name environment variable name format: [NAME]_[DATABASE_TYPE]_DATABASE
  database=$(find_env "${prefix}_DATABASE")

  if [ -z "$jndi" ] || [ -z "$username" ] || [ -z "$password" ]; then
    log_warning "Ooops, there is a problem with the ${db,,} datasource!"
    log_warning "In order to configure ${db,,} datasource for $prefix service you need to provide following environment variables: ${prefix}_USERNAME and ${prefix}_PASSWORD."
    log_warning
    log_warning "Current values:"
    log_warning
    log_warning "${prefix}_USERNAME: $username"
    log_warning "${prefix}_PASSWORD: $password"
    log_warning "${prefix}_JNDI: $jndi"
    log_warning
    log_warning "The ${db,,} datasource for $prefix service WILL NOT be configured."
    continue
  fi

  # Transaction isolation level environment variable name format: [NAME]_[DATABASE_TYPE]_TX_ISOLATION
  tx_isolation=$(find_env "${prefix}_TX_ISOLATION")

  # min pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MIN_POOL_SIZE
  min_pool_size=$(find_env "${prefix}_MIN_POOL_SIZE")

  # max pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MAX_POOL_SIZE
  max_pool_size=$(find_env "${prefix}_MAX_POOL_SIZE")

  # jta environment variable name format: [NAME]_[DATABASE_TYPE]_JTA
  jta=$(find_env "${prefix}_JTA" true)

  # $NON_XA_DATASOURCE: [NAME]_[DATABASE_TYPE]_NONXA (DB_NONXA)
  NON_XA_DATASOURCE=$(find_env "${prefix}_NONXA" false)

  url=$(find_env "${prefix}_URL")
  driver=$(find_env "${prefix}_DRIVER" )
  checker=$(find_env "${prefix}_CONNECTION_CHECKER" )
  sorter=$(find_env "${prefix}_EXCEPTION_SORTER" )
  url=$(find_env "${prefix}_URL" )
  if [ -n "$checker" ] && [ -n "$sorter" ]; then
    validate=true
  else
    validate="false"
  fi

  service_name=$prefix

  if [ -z "$jta" ]; then
    log_warning "JTA flag not set, defaulting to true for datasource  ${service_name}"
    jta=false
  fi

  if [ -z "$driver" ]; then
    log_warning "DRIVER not set for datasource ${service_name}. Datasource will not be configured."
  else
    datasource=$(generate_datasource "${service,,}-${prefix}" "$jndi" "$username" "$password" "$host" "$port" "$database" "$checker" "$sorter" "$driver" "$service_name" "$jta" "$validate" "$url")

    if [ -n "$datasource" ]; then
      local dsConfMode
      getDataSourceConfigureMode "dsConfMode"
      if [ "${dsConfMode}" = "xml" ]; then
        sed -i "s|<!-- ##DATASOURCES## -->|${datasource}\n<!-- ##DATASOURCES## -->|" $CONFIG_FILE
      elif [ "${dsConfMode}" = "cli" ]; then
        echo "${datasource}" >> ${CLI_SCRIPT_FILE}
      fi
    fi

  fi
}

function get_jndi_name() {
  local prefix=$1
  echo $(find_env "${prefix}_JNDI" "java:jboss/datasources/${service,,}")
}
