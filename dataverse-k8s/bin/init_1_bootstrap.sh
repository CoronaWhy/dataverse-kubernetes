#!/bin/bash
################################################################################
# Configure Glassfish
#
# BEWARE: As this is done for Kubernetes, we will ALWAYS start with a fresh container!
#         When moving to Glassfish/Payara 5+ the option commands are idempotent.
#         The resources are to be created by the application on deployment,
#         once Dataverse has proper refactoring, etc.
#         See upstream issue IQSS/dataverse#5292
################################################################################

# Fail on any error
set -e
# Include some sane defaults
. ${SCRIPT_DIR}/default.config

# 0. Start the domain
asadmin start-domain

# 1. Password aliases from secrets
for alias in rserve_password_alias doi_password_alias db_password_alias storage_password_alias
do
  if [ -f ${SECRETS_DIR}/$alias ]; then
    asadmin $ASADMIN_OPTS create-password-alias --passwordfile ${SECRETS_DIR}/$alias $alias
  else
    echo "Could not find secret for $alias in $SECRETS_DIR. Check your Kubernetes Secrets!"
  fi
done

# 2. Domain-spaced resources (JDBC, JMS, ...)

# JMS
asadmin delete-connector-connection-pool --cascade=true jms/__defaultConnectionFactory-Connection-Pool
asadmin create-connector-connection-pool \
          --steadypoolsize 1 \
          --maxpoolsize 250 \
          --poolresize 2 \
          --maxwait 60000 \
          --raname jmsra \
          --connectiondefinition javax.jms.QueueConnectionFactory \
          jms/IngestQueueConnectionFactoryPool
asadmin create-connector-resource \
          --poolname jms/IngestQueueConnectionFactoryPool \
          --description "ingest connector resource" \
          jms/IngestQueueConnectionFactory
asadmin create-admin-object \
          --restype javax.jms.Queue \
          --raname jmsra \
          --description "sample administered object" \
          --property Name=DataverseIngest \
          jms/DataverseIngest

# JDBC
asadmin create-jdbc-connection-pool \
          --restype javax.sql.DataSource \
          --datasourceclassname org.postgresql.ds.PGPoolingDataSource \
          --property create=true:User=${POSTGRES_USER}:PortNumber=${POSTGRES_PORT}:databaseName=${POSTGRES_DATABASE}:ServerName=${POSTGRES_SERVER} \
          dvnDbPool
asadmin set resources.jdbc-connection-pool.dvnDbPool.property.password='${ALIAS=db_password_alias}'
asadmin create-jdbc-resource --connectionpoolid dvnDbPool jdbc/VDCNetDS

# JavaMail
asadmin create-javamail-resource \
          --mailhost "${MAIL_SERVER}" \
          --mailuser "dataversenotify" \
          --fromaddress "do-not-reply@${HOST_DNS_ADDRESS}" \
          mail/notifyMailSession

# Timer data source
asadmin set configs.config.server-config.ejb-container.ejb-timer-service.timer-datasource=jdbc/VDCNetDS
# AJP connector
asadmin create-network-listener --protocol http-listener-1 --listenerport 8009 --jkenabled true jk-connector
# Disable logging for grizzly SSL problems
asadmin set-log-levels org.glassfish.grizzly.http.server.util.RequestUtils=SEVERE
# COMET support
asadmin set server-config.network-config.protocols.protocol.http-listener-1.http.comet-support-enabled="true"
# SAX parser options
asadmin create-jvm-options "\-Djavax.xml.parsers.SAXParserFactory=com.sun.org.apache.xerces.internal.jaxp.SAXParserFactoryImpl"

# 3. Domain based configuration options
# t.b.d.: use script to map DATAVERSE_XXX_XXX to system properties -Ddataverse.xxx.xxx

# 4. Stop the domain again (will be started in foreground later)
asadmin stop-domain

# 5. Symlink the WAR file to autodeploy on real start
ln -s ${HOME_DIR}/dvinstall/dataverse.war ${DOMAIN_DIR}/autodeploy/dataverse.war