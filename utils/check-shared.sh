#!/bin/bash -e
DISCONNECT=false
WAIT_TIME=300
NODE="*"
SHARED_KEY="MULTI_MASTER_SLAVE"
while [[ $# -gt 0 ]] ; do
  opt=$1; shift
  case $opt in
    -n|--node)         NODE="$1"; shift ;;
    -w|--wait-time)    WAIT_TIME=$1; shift ;;
    -d|--disconnect)   DISCONNECT=true ;;
    -k|--key)          SHARED_KEY=$1; shift ;;
  esac
done
if [ ${WAIT_TIME} -lt 60 ] ; then WAIT_TIME=60; fi
mkdir -p nodes
JENKINS_PORT=$(pgrep -x -a  -f ".*httpPort=.*" | tail -1 | tr ' ' '\n' | grep httpPort | sed 's|.*=||')
LOCAL_URL=$(echo $HUDSON_URL | sed "s|https://[^/]*/|http://localhost:${JENKINS_PORT}/|")
ERR=0
for n in $(grep -H "${SHARED_KEY}" $HOME/nodes/${NODE}/config.xml 2>/dev/null  | sed 's|/config.xml *:.*||;s|.*/||') ; do
  echo "Working on $n ..."
  curl -s "${LOCAL_URL}/computer/$n/api/json?pretty=true" > data
  cleanup=true
  if [ $(grep '"offline"' data | grep 'false' | wc -l) -gt 0 ] ; then
    echo "  Connected"
    if [ $(grep '"idle"' data | grep 'true' | wc -l) -gt 0 ] ; then
      echo "  Idle"
      cleanup=false
      if [ -f nodes/$n ] ; then
        let age=$(date +%s)-$(date +%s -r "nodes/$n") || true
        echo "  Time since idle: ${age}s"
        if [ $age -gt ${WAIT_TIME} ] ; then
          if [ $(curl -s -H "ADFS_LOGIN: localcli" "${LOCAL_URL}/computer/$n/api/json?pretty=true" | grep '"idle"' | grep "true" |wc -l) -gt 0 ] ; then
            echo "  Disconnecting $n"
            if $DISCONNECT ; then
              ${JENKINS_CLI_CMD} disconnect-node "$n"
            else
              ERR=1
            fi
          fi
          rm -f nodes/$n
        fi
      else
        touch nodes/$n
      fi
    else
      echo "  Busy"
    fi
  else
    echo "  Disconnected"
  fi
  if $cleanup ; then rm -f nodes/$n ; fi
done
exit $ERR
