#!/bin/bash -eu

# Resolve dependencies and download plugins given on the command line
#
# FROM jenkins
# RUN install-plugins.sh docker-slaves github-branch-source

set -o pipefail

REF_DIR=${REF:-/build/plugin-ref/plugins}
FAILED="$REF_DIR/failed-plugins.txt"
DEPS="$REF_DIR/deps-plugins.txt"
JENKINS_UC=https://updates.jenkins.io
let PARALLEL_JOBS=$(getconf _NPROCESSORS_ONLN)*2

. $(dirname $0)/jenkins-support

getLockFile() {
    printf '%s' "$REF_DIR/${1}.lock"
}

getArchiveFilename() {
    printf '%s' "$REF_DIR/${1}.jpi"
}

download() {
    local plugin originalPlugin version lock ignoreLockFile
    plugin="$1"
    version="${2:-latest}"
    ignoreLockFile="${3:-}"
    lock="$(getLockFile "$plugin")"

    if [[ $ignoreLockFile ]] || mkdir "$lock" &>/dev/null; then
        if ! doDownload "$plugin" "$version"; then
            # some plugin don't follow the rules about artifact ID
            # typically: docker-plugin
            originalPlugin="$plugin"
            plugin="${plugin}-plugin"
            if ! doDownload "$plugin" "$version"; then
                echo "Failed to download plugin: $originalPlugin or $plugin" >&2
                echo "Not downloaded: ${originalPlugin}" >> "$FAILED"
                return 1
            fi
        fi

        if ! checkIntegrity "$plugin"; then
            echo "Downloaded file is not a valid ZIP: $(getArchiveFilename "$plugin")" >&2
            echo "Download integrity: ${plugin}" >> "$FAILED"
            return 1
        fi

        resolveDependencies "$plugin"
    fi
}

doDownload() {
    local plugin version url jpi cversion
    plugin="$1"
    version="$2"
    jpi="$(getArchiveFilename "$plugin")"

    if [ "$version" != "latest" ] ; then
      if test -f "$jpi" ; then
        cversion=$(unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | grep "^Plugin-Version:" | sed 's|^Plugin-Version: *||')
        if [ "$(echo -e "$version\n$cversion" | sort | tail -1)" = "$cversion" ] ; then
          echo "Using existing newer version: $plugin $version (existing: $cversion)"
          return 0
        fi
      fi
    fi

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

    echo "Downloading plugin: $plugin from $url"
    curl --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" --retry "${CURL_RETRY:-5}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" -s -f -L "$url" -o "$jpi"
    return $?
}

checkIntegrity() {
    local plugin jpi
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    unzip -t -qq "$jpi" >/dev/null
    return $?
}

resolveDependencies() {
    local plugin jpi dependencies
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    dependencies="$(unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | tr '\n' '|' | sed -e 's#| ##g' | tr '|' '\n' | grep "^Plugin-Dependencies: " | sed -e 's#^Plugin-Dependencies: ##')"

    if [[ ! $dependencies ]]; then
        return
    fi

    IFS=',' read -r -a array <<< "$dependencies"

    for d in "${array[@]}"
    do
        plugin="$(cut -d':' -f1 - <<< "$d")"
        if [[ $d == *"resolution:=optional"* ]]; then
            continue
        elif [ ! -d $REF_DIR/${plugin}.lock ] ; then 
            echo "$d" >> $DEPS
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
    if [[ ($# -eq 0) ]]; then
      while read -r line; do plugins="$plugins $line" ; done
    elif [ -f $1 ] ; then
      plugins=$(cat $1 | tr '\n' ' ')  
    else
      plugins="$@"
    fi

    if [ -f $1 ] ; then
      plugins=$(cat $1)
    else
      plugins="$@"
    fi

    # Create lockfile manually before first run to make sure any explicit version set is used.
    echo "Creating initial locks..."
    for plugin in $plugins; do
        mkdir "$(getLockFile "${plugin%%:*}")"
    done

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

    echo "Downloading plugins..."
    for plugin in $plugins; do
        while [ $(jobs -p | wc -l) -ge ${PARALLEL_JOBS} ] ; do sleep 1 ; done
        pluginVersion=""

        if [[ $plugin =~ .*:.* ]]; then
            pluginVersion=$(versionFromPlugin "${plugin}")
            plugin="${plugin%%:*}"
        fi
        download "$plugin" "$pluginVersion" "true" &
    done
    wait

    echo
    echo "WAR bundled plugins:"
    echo "${bundledPlugins}"
    if [[ -f $FAILED ]]; then
        echo "Some plugins failed to download!" "$(<"$FAILED")" >&2
        for p in $(cat $FAILED | sed 's|i.*:  *||') ; do
          rm -f $REF_DIR/$p.jpi
        done
        rm -f $FAILED
        exit 1
    fi
}

main "$@"
while [ -s $DEPS ] ; do
  rm -f ${DEPS}.uniq
  touch ${DEPS}.uniq
  for p in $(cat $DEPS | sed -e 's|:.*$||' | sort -u) ; do
    grep "^$p:" $DEPS | tail -1 >> ${DEPS}.uniq
  done
  echo "============== deps ========="
  cat ${DEPS}.uniq
  echo "----------------------------"
  main "${DEPS}.uniq"
done

echo "Cleaning up locks"
rm -fr "$REF_DIR"/*.lock || true
