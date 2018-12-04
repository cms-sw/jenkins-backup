#!/bin/bash -eu
set -o pipefail

export REF_DIR=${JENKINS_PLUGIN_REF:-/var/lib/jenkins/plugin-ref/plugins}
FAILED="$REF_DIR/failed-plugins.txt"
DEPS="$REF_DIR/deps-plugins.txt"
JENKINS_UC="https://updates.jenkins.io"
CMSCOPY="http://muzaffar.web.cern.ch/muzaffar/jenkins-plugins/"
PLUGIN_LIST=""
JENKINS_WAR=$(ps -awx | grep ' \-jar /' | grep '/jenkins.war' | sed 's|.*-jar /|/|;s| .*||' | tail -1)
export JENKINS_WAR
let PARALLEL_JOBS=$(getconf _NPROCESSORS_ONLN)*2

. $(dirname $0)/jenkins-support

getLockFile() {
  printf '%s' "$REF_DIR/lock/${1}"
}

getArchiveFilename() {
    printf '%s' "$REF_DIR/${1}.jpi"
}

download() {
    local plugin version jpi url
    plugin="$1"
    version="${2:-latest}"
    jpi="$(getArchiveFilename "$plugin")"
    if ! doDownload "$plugin" "$version"; then
      if ! doDownload "$plugin-plugin" "$version"; then
        url="${CMSCOPY}/${plugin}.jpi"
        if ! downloadURL "$plugin" "$jpi" "$url" ; then
          echo "Failed to download plugin: $plugin or ${plugin}-plugin" >&2
          echo "Not downloaded: ${plugin}" >> "$FAILED"
          rm -f "$jpi"
          return 1
        fi
      fi
    fi

    if ! checkIntegrity "$plugin"; then
      echo "Downloaded file is not a valid ZIP: $(getArchiveFilename "$plugin")" >&2
      echo "Download integrity: ${plugin}" >> "$FAILED"
      rm -f "$jpi"
      return 1
    fi
    if [ "$version" = "latest" ] ; then touch "$jpi.latest" ; fi
    resolveDependencies "$plugin"
}

getPluginVersion() {
  local jpi
  jpi="$(getArchiveFilename "$1")"
  if test -f "$jpi" ; then
     echo $(unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | grep "^Plugin-Version:" | sed 's|^Plugin-Version: *||')
  else
    echo ""
  fi
}

hasNewerVersion() {
  local xv cv
  xv=$(echo $2 | sed -e s'|-.*$||')
  cv="$(getPluginVersion "$1")"
  if [ "$(echo -e "$xv\n$cv" | sort -V | tail -1)" = "$cv" ] ; then
    return 0
  fi
  return 1
}

doDownload() {
    local plugin version url jpi cversion
    plugin="$1"
    version="$2"
    if [ "$version" != "latest" ] ; then
      if hasNewerVersion "$plugin" "$version" ;then echo "Installed: $plugin $version"; return 0; fi
    fi
    jpi="$(getArchiveFilename "$plugin")"
    rm -f "$jpi"
    if [[ "$version" == "latest" && -n "$JENKINS_UC_LATEST" ]]; then
        # If version-specific Update Center is available, which is the case for LTS versions,
        # use it to resolve latest versions.
        url="$JENKINS_UC_LATEST/latest/${plugin}.hpi"
    elif [[ "$version" == "experimental" && -n "$JENKINS_UC_EXPERIMENTAL" ]]; then
        # Download from the experimental update center
        url="$JENKINS_UC_EXPERIMENTAL/latest/${plugin}.hpi"
    else
        JENKINS_UC_DOWNLOAD=${JENKINS_UC_DOWNLOAD:-"$JENKINS_UC/download"}
        url="$JENKINS_UC_DOWNLOAD/plugins/$plugin/$version/${plugin}.hpi"
    fi
    if ! downloadURL "$plugin" "$jpi" "$url" ; then return 1 ; fi
    return 0
}


downloadURL() {
  echo "Downloading plugin: $1 from $3"
  curl --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" --retry "${CURL_RETRY:-5}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" -s -f -L "$3" -o "$2"
  return $?
}

checkIntegrity() {
    local jpi
    jpi="$(getArchiveFilename "$1")"
    unzip -t -qq "$jpi" >/dev/null
    return $?
}

resolveDependencies() {
    local plugin jpi dependencies cv lock
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    dependencies="$(unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | tr '\n' '|' | sed -e 's#| ##g' | tr '|' '\n' | grep "^Plugin-Dependencies: " | sed -e 's#^Plugin-Dependencies: ##')"

    if [[ ! $dependencies ]]; then return ; fi

    IFS=',' read -r -a array <<< "$dependencies"

    for d in "${array[@]}" ; do
      if [[ $d == *"resolution:=optional"* ]]; then
        continue
      else
         plugin="$(cut -d':' -f1 - <<< "$d")"
         cv="$(cut -d':' -f2 - <<< "$d")"
         lock="$(getLockFile "$plugin")"
         if [ ! -d "$lock" ] ; then
          echo "$plugin:$cv" >> $DEPS
        fi
      fi
    done
}

versionFromPlugin() {
    local plugin=$1
    if [[ $plugin =~ .*:.* ]]; then
        echo "${plugin##*:}"
    else
        echo "latest"
    fi

}

installedPlugins() {
    for f in "$REF_DIR"/*.jpi; do
        echo "$(basename "$f" | sed -e 's/\.jpi//'):$(get_plugin_version "$f")"
    done
}

main() {
    local plugin pluginVersion jenkinsVersion
    local plugins=()

    mkdir -p "$REF_DIR" || exit 1
    rm -f $FAILED
    rm -f $DEPS
    touch $DEPS
    plugins=$(cat $1)

    echo "Analyzing war..."
    bundledPlugins="$(bundledPlugins)"

    # Check if there's a version-specific update center, which is the case for LTS versions
    jenkinsVersion="$(jenkinsMajorMinorVersion)"
    if curl -fsL -o /dev/null "$JENKINS_UC/$jenkinsVersion"; then
        JENKINS_UC_LATEST="$JENKINS_UC/$jenkinsVersion"
        echo "Using version-specific update center: $JENKINS_UC_LATEST..."
    else
        JENKINS_UC_LATEST=
    fi

    for plugin in $plugins; do
      mkdir "$(getLockFile "${plugin%%:*}")"
    done

    echo "Downloading plugins..."
    for plugin in $plugins; do
        while [ $(jobs -p | wc -l) -ge ${PARALLEL_JOBS} ] ; do sleep 1; done
        pluginVersion=""
        if [[ $plugin =~ .*:.* ]]; then
            pluginVersion=$(versionFromPlugin "${plugin}")
            plugin="${plugin%%:*}"
        fi
        download "$plugin" "$pluginVersion" &
    done
    wait

    echo
    echo "WAR bundled plugins:"
    echo "${bundledPlugins}"
    if [[ -f $FAILED ]]; then
        echo "Some plugins failed to download!" "$(<"$FAILED")" >&2
        rm -f $FAILED
        rm -rf "$REF_DIR/*.lock"
        exit 1
    fi
}

rm -rf "$REF_DIR/lock"
mkdir -p "$REF_DIR/lock"
PLUGIN_LIST=$1
main "$2"
while [ -s $DEPS ] ; do
  rm -f ${DEPS}.uniq
  touch ${DEPS}.uniq
  for p in $(cat $DEPS | sed -e 's|:.*$||' | sort -u) ; do
    list_ver=$(grep "^$p:" $PLUGIN_LIST | sed -e 's|.*:||' | sort -V | tail -1)
    max_ver1=$(grep "^$p:" $DEPS | sed -e 's|.*:||' | sort -V | tail -1)
    max_ver=$(echo -e "$list_ver\n$max_ver1" | sort -V | tail -1)
    echo "$p:$max_ver" >>  ${DEPS}.uniq
  done
  main "${DEPS}.uniq"
done
rm -rf "$REF_DIR/lock"

