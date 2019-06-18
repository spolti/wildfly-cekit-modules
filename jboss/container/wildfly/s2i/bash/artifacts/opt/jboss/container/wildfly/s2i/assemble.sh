#!/bin/sh

set -e

function copy_server_s2i_output() {
  mkdir -p $WILDFLY_S2I_OUTPUT_DIR
  echo "Copying server to $WILDFLY_S2I_OUTPUT_DIR"
  cp -r -L $JBOSS_HOME $WILDFLY_S2I_OUTPUT_DIR/server  
}

source "${JBOSS_CONTAINER_UTIL_LOGGING_MODULE}/logging.sh"
source "${JBOSS_CONTAINER_MAVEN_S2I_MODULE}/maven-s2i"

# include our overrides/extensions
source "${JBOSS_CONTAINER_WILDFLY_S2I_MODULE}/s2i-core-hooks"

# Galleon integration
source "${JBOSS_CONTAINER_WILDFLY_S2I_MODULE}/galleon/s2i_galleon"

galleon_provision_server

# invoke the build
maven_s2i_build

copy_server_s2i_output