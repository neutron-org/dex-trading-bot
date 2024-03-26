description="${1:-"saved"}"
# if container is not currently running then let user know
container="$( docker ps --filter name=neutron-node -q )"
if [ -z "$container" ]
then
    echo "run container first: eg. \`make start-neutron-node\`, you can remove it after with  \`make stop-neutron-node\`"
    exit 1
fi

docker exec $container mkdir /opt/neutron/backup-data
docker exec $container cp -a /opt/neutron/data/. /opt/neutron/backup-data/
docker commit $container "neutron-node:$description"
docker exec $container rm -rf /opt/neutron/backup-data
