#!/usr/bin/env bash
set -euo pipefail

cd /data

STATE_DIR="server-state"
mkdir -p "/data/${STATE_DIR}" /data/world

download_tool() {
  if command -v curl >/dev/null 2>&1; then
    echo curl
  elif command -v wget >/dev/null 2>&1; then
    echo wget
  else
    echo "" >&2
    return 1
  fi
}

serverstarterjar_url() {
  local version
  version="$(grep -E '^SERVERSTARTERJAR_VERSION=' /data/variables.txt | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
  if [[ "${version}" == "latest" ]]; then
    echo "https://github.com/neoforged/ServerStarterJar/releases/latest/download/server.jar"
  else
    echo "https://github.com/neoforged/ServerStarterJar/releases/download/${version}/server.jar"
  fi
}

download_to() {
  local dest="$1"
  local url="$2"
  local tool status=0
  tool="$(download_tool)" || {
    echo "ERROR: curl or wget is required to download server.jar." >&2
    exit 1
  }
  if [[ "${tool}" == "curl" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "${dest}" "${url}" || status=$?
  else
    wget -O "${dest}" "${url}" || status=$?
  fi
  if [[ "${status}" -ne 0 ]]; then
    rm -f "${dest}"
    echo "ERROR: download failed (${status}): ${url}" >&2
    exit "${status}"
  fi
}

is_jar() {
  local magic
  magic="$(head -c 2 "$1" 2>/dev/null || true)"
  [[ "${magic}" == "PK" ]]
}

eula_accepted_env() {
  case "${EULA:-}" in
    TRUE|true|1|yes|YES|True) return 0 ;;
    *) return 1 ;;
  esac
}

seed_eula_on_volume() {
  local vol="/data/${STATE_DIR}/eula.txt"
  if [[ -s "${vol}" ]]; then
    return 0
  fi
  if eula_accepted_env; then
    {
      echo "#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA)."
      echo "eula=true"
    } >"${vol}"
    return 0
  fi
  echo "ERROR: Mojang EULA not accepted. Set environment variable EULA=TRUE (or true/1) to run this server." >&2
  echo "See https://aka.ms/MinecraftEULA" >&2
  exit 1
}

ensure_state_file() {
  local f="$1"
  local vol="/data/${STATE_DIR}/${f}"
  local data="/data/${f}"

  if [[ ! -f "${vol}" ]]; then
    if [[ -f "${data}" && ! -L "${data}" ]]; then
      mv "${data}" "${vol}"
    elif [[ "${f}" == "eula.txt" ]]; then
      seed_eula_on_volume
    elif [[ "${f}" == "server.properties" ]]; then
      if [[ -f "${data}" && ! -L "${data}" ]]; then
        cp "${data}" "${vol}"
      fi
    elif [[ "${f}" == "whitelist.json" || "${f}" == "ops.json" || "${f}" == "banned-players.json" || "${f}" == "banned-ips.json" || "${f}" == "usercache.json" ]]; then
      echo "[]" >"${vol}"
    fi
  fi

  if [[ ! -f "${vol}" ]]; then
    return 0
  fi

  if [[ -L "${data}" ]]; then
    local target
    target="$(readlink "${data}")"
    if [[ "${target}" == "${STATE_DIR}/${f}" ]]; then
      return 0
    fi
    rm -f "${data}"
  elif [[ -f "${data}" ]]; then
    rm -f "${data}"
  fi

  ln -sf "${STATE_DIR}/${f}" "${data}"
}

ensure_state_dir_link() {
  local name="$1"
  local vol="/data/${STATE_DIR}/${name}"
  local data="/data/${name}"

  mkdir -p "${vol}"

  if [[ -L "${data}" ]]; then
    local target
    target="$(readlink "${data}")"
    if [[ "${target}" == "${STATE_DIR}/${name}" ]]; then
      return 0
    fi
    rm -f "${data}"
  elif [[ -d "${data}" ]]; then
    shopt -s dotglob nullglob
    local items=("${data}"/*)
    if [[ ${#items[@]} -gt 0 ]]; then
      mv "${items[@]}" "${vol}/"
    fi
    shopt -u dotglob nullglob
    rmdir "${data}" 2>/dev/null || rm -rf "${data}"
  elif [[ -e "${data}" ]]; then
    rm -f "${data}"
  fi

  ln -sf "${STATE_DIR}/${name}" "${data}"
}

ensure_server_jar() {
  local vol="/data/${STATE_DIR}/server.jar"
  local data="/data/server.jar"

  if [[ ! -s "${vol}" ]] || ! is_jar "${vol}"; then
    rm -f "${vol}"
    if [[ -f "${data}" && ! -L "${data}" ]] && is_jar "${data}"; then
      mv "${data}" "${vol}"
    else
      echo "Downloading ServerStarterJar to persistent volume..." >&2
      download_to "${vol}" "$(serverstarterjar_url)"
    fi
  fi

  if [[ ! -s "${vol}" ]] || ! is_jar "${vol}"; then
    echo "ERROR: server.jar is missing or is not a jar." >&2
    exit 1
  fi

  if [[ -L "${data}" ]]; then
    local target
    target="$(readlink "${data}")"
    if [[ "${target}" == "${STATE_DIR}/server.jar" ]]; then
      return 0
    fi
    rm -f "${data}"
  elif [[ -f "${data}" ]]; then
    rm -f "${data}"
  fi

  ln -sf "${STATE_DIR}/server.jar" "${data}"
}

set_variables_key() {
  local key="$1"
  local value="$2"
  local file="/data/variables.txt"
  local tmp
  tmp="$(mktemp)"
  awk -v k="${key}" -v v="${value}" '
    BEGIN {
      ek = k
      gsub(/[.\\^$|()*+?{}\[\]]/, "\\\\&", ek)
      found = 0
    }
    $0 ~ ("^" ek "=") { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

patch_variables_txt() {
  local mem="${MEMORY:-4G}"
  if [[ ! "${mem}" =~ ^[0-9]+[gGmMkK]$ ]]; then
    echo "ERROR: MEMORY must look like 4G or 512M (got '${mem}')." >&2
    exit 1
  fi
  set_variables_key "WAIT_FOR_USER_INPUT" "false"
  set_variables_key "RESTART" "false"
  set_variables_key "SKIP_JAVA_CHECK" "true"
  set_variables_key "JAVA" "java"
  set_variables_key "JAVA_ARGS" "\"-Xms${mem} -Xmx${mem}\""
  set_variables_key "SERVERSTARTERJAR_FORCE_FETCH" "false"
}

set_prop() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v k="${key}" -v v="${value}" '
    BEGIN {
      ek = k
      gsub(/[.\\^$|()*+?{}\[\]]/, "\\\\&", ek)
      found = 0
    }
    $0 ~ ("^" ek "=") { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

patch_server_properties() {
  local props="/data/${STATE_DIR}/server.properties"
  [[ -f "${props}" ]] || return 0

  # level-name=world is the link between server.properties and the sunlit_world volume.
  set_prop "${props}" "level-name" "world"
  set_prop "${props}" "server-port" "25565"

  if [[ -n "${MOTD:-}" ]]; then
    set_prop "${props}" "motd" "${MOTD}"
  fi

  if [[ -n "${MAX_PLAYERS:-}" ]]; then
    if [[ ! "${MAX_PLAYERS}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: MAX_PLAYERS must be a number (got '${MAX_PLAYERS}')." >&2
      exit 1
    fi
    set_prop "${props}" "max-players" "${MAX_PLAYERS}"
  fi

  if [[ -n "${ONLINE_MODE:-}" ]]; then
    set_prop "${props}" "online-mode" "${ONLINE_MODE}"
  fi

  if [[ -n "${RCON_PASSWORD:-}" ]]; then
    set_prop "${props}" "enable-rcon" "true"
    set_prop "${props}" "rcon.password" "${RCON_PASSWORD}"
    set_prop "${props}" "rcon.port" "25575"
  fi
}

patch_ftb_backups() {
  local cfg="/data/config/ftbbackups2.json"
  [[ -f "${cfg}" ]] || return 0
  if grep -q '"backup_location"' "${cfg}"; then
    sed -i 's|"backup_location"[[:space:]]*:[[:space:]]*"[^"]*"|"backup_location": "./backups"|' "${cfg}"
  fi
}

# Identity and persisted server files
for f in eula.txt server.properties whitelist.json ops.json banned-players.json banned-ips.json usercache.json; do
  ensure_state_file "${f}"
done

ensure_state_dir_link libraries
ensure_state_dir_link logs
ensure_state_dir_link backups

ensure_server_jar

patch_variables_txt
patch_server_properties
patch_ftb_backups

# start.sh is shipped read-only and pause() always waits for a key, including
# after crashServer. Honor WAIT_FOR_USER_INPUT on the container copy only.
prepare_start_script() {
  chmod u+w /data/start.sh
  if grep -q 'WAIT_FOR_USER_INPUT:-true' /data/start.sh; then
    chmod +x /data/start.sh
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { done = 0 }
    /^pause\(\) \{/ && !done {
      print
      print "  if [[ \"${WAIT_FOR_USER_INPUT:-true}\" == \"false\" || ! -t 0 ]]; then return 0; fi"
      done = 1
      next
    }
    { print }
  ' /data/start.sh >"${tmp}"
  mv "${tmp}" /data/start.sh
  chmod +x /data/start.sh
}

prepare_start_script

shutting_down=false

# /proc/<pid>/stat comm is wrapped in parentheses and may contain spaces.
# Fields after the closing paren: state, ppid, pgrp, ...
proc_ppid() {
  local stat rest state ppid
  stat="$(cat "/proc/${1}/stat")"
  rest="${stat#*) }"
  read -r state ppid _ <<<"${rest}"
  printf '%s' "${ppid}"
}

proc_comm() {
  local stat
  stat="$(cat "/proc/${1}/stat")"
  stat="${stat#*(}"
  printf '%s' "${stat%%)*}"
}

# Deepest Java descendant of start.sh. ServerStarterJar may spawn the real server
# as a child JVM; that child owns the world and must receive SIGTERM first.
find_server_java() {
  local root="$1"
  local pid_path pid comm ppid depth best_pid best_depth walk
  best_pid=""
  best_depth=-1
  for pid_path in /proc/[0-9]*; do
    pid="${pid_path#/proc/}"
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    [[ -r "${pid_path}/stat" ]] || continue
    comm="$(proc_comm "${pid}")"
    [[ "${comm}" == "java" ]] || continue
    depth=0
    walk="${pid}"
    while [[ -n "${walk}" && "${walk}" != "0" && "${walk}" != "1" ]]; do
      if [[ "${walk}" == "${root}" ]]; then
        if [[ "${depth}" -gt "${best_depth}" ]]; then
          best_depth="${depth}"
          best_pid="${pid}"
        fi
        break
      fi
      ppid="$(proc_ppid "${walk}")" || break
      [[ "${ppid}" == "${walk}" ]] && break
      walk="${ppid}"
      depth=$((depth + 1))
    done
  done
  [[ -n "${best_pid}" ]] || return 1
  printf '%s' "${best_pid}"
}

# Stay in the foreground process group (no monitor mode). A TTY plus `set -m`
# would put the server in a background group, and its console read would stop
# on SIGTTIN before any later SIGTERM could save the world.
shutdown() {
  local java=""
  shutting_down=true
  trap - TERM INT
  if [[ -n "${child:-}" ]]; then
    java="$(find_server_java "${child}" || true)"
    if [[ -n "${java}" ]]; then
      kill -TERM "${java}" 2>/dev/null || true
      while [[ -d "/proc/${java}" ]]; do
        sleep 0.2
      done
    fi
    if [[ -d "/proc/${child}" ]]; then
      kill -TERM "${child}" 2>/dev/null || true
    fi
    set +e
    wait "${child}" 2>/dev/null
    set -e
  fi
  exit 0
}

trap shutdown TERM INT

./start.sh &
child=$!

set +e
wait "${child}"
exit_status=$?
set -e

if [[ "${shutting_down}" == "true" ]]; then
  exit 0
fi
exit "${exit_status}"
