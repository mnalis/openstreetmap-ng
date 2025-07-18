{
  isDevelopment ? true,
  hostMemoryMb ? 8192,
  hostDiskCoW ? false,
  enablePostgres ? true,
  postgresPort ? 49560,
  postgresSharedBuffersPerc ? 0.3,
  postgresWorkMemMb ? 64,
  postgresWorkers ?
    postgresParallelWorkers + postgresAutovacuumWorkers + postgresTimescaleWorkers + 1,
  postgresParallelWorkers ? postgresParallelMaintenanceWorkers * 8,
  postgresParallelMaintenanceWorkers ? 1,
  postgresAutovacuumWorkers ? 2,
  postgresTimescaleWorkers ? 3,
  postgresIOConcurrency ? 300,
  postgresRandomPageCost ? 1.1,
  postgresMinWalSizeGb ? 1,
  postgresMaxWalSizeGb ? 10,
  postgresVerbose ? 2, # 0 = no, 1 = some, 2 = most
  enableMailpit ? true,
  mailpitHttpPort ? 49566,
  mailpitSmtpPort ? 49565,
  gunicornWorkers ? 1,
  gunicornPort ? 8000,
}:

let
  # Update packages with `nixpkgs-update` command
  pkgs =
    import
      (fetchTarball "https://github.com/NixOS/nixpkgs/archive/3078b9a9e75f1790e6d6ef9955fdc6a2d1740cc6.tar.gz")
      { };

  projectDir = toString ./.;
  preCommitConf = import ./config/pre-commit-config.nix {
    inherit pkgs makeScript;
  };
  preCommitHook = import ./config/pre-commit-hook.nix {
    inherit pkgs projectDir preCommitConf;
  };
  postgresArgs = {
    inherit
      hostMemoryMb
      hostDiskCoW
      postgresPort
      postgresSharedBuffersPerc
      postgresWorkMemMb
      postgresWorkers
      postgresParallelWorkers
      postgresParallelMaintenanceWorkers
      postgresAutovacuumWorkers
      postgresTimescaleWorkers
      postgresIOConcurrency
      postgresRandomPageCost
      postgresMinWalSizeGb
      postgresMaxWalSizeGb
      postgresVerbose
      pkgs
      projectDir
      ;
  };
  postgresConf = import ./config/postgres.nix postgresArgs;
  postgresFastIngestConf = import ./config/postgres.nix (
    postgresArgs
    // {
      postgresWorkers = postgresWorkers - postgresAutovacuumWorkers;
      postgresAutovacuumWorkers = 0;
      fastIngest = true;
    }
  );
  processComposeArgs = {
    inherit
      isDevelopment
      enablePostgres
      enableMailpit
      mailpitHttpPort
      mailpitSmtpPort
      pkgs
      postgresConf
      ;
  };
  processComposeConf = import ./config/process-compose.nix processComposeArgs;
  processComposeFastIngestConf = import ./config/process-compose.nix (
    processComposeArgs // { postgresConf = postgresFastIngestConf; }
  );

  pythonLibs = with pkgs; [
    cairo.out
    file.out
    libyaml.out
    libxml2.out
    openssl.out
    zlib.out
    stdenv.cc.cc.lib
  ];
  python' =
    with pkgs;
    symlinkJoin {
      name = "python";
      paths = [
        # Enable compiler optimizations when in production
        (if isDevelopment then python313 else python313.override { enableOptimizations = true; })
      ];
      buildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram "$out/bin/python3.13" \
          --prefix ${if stdenv.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH"} : \
          "${lib.makeLibraryPath pythonLibs}"
      '';
    };
  watchexec' = makeScript "watchexec" ''
    exec ${pkgs.watchexec}/bin/watchexec --wrap-process=none "$@"
  '';

  # https://github.com/NixOS/nixpkgs/blob/nixpkgs-unstable/pkgs/build-support/trivial-builders/default.nix
  makeScript =
    with pkgs;
    name: text:
    writeTextFile {
      inherit name;
      executable = true;
      destination = "/bin/${name}";
      text = ''
        #!${runtimeShell} -e
        shopt -s extglob nullglob globstar
        cd "${projectDir}"
        ${text}
      '';
      checkPhase = ''
        ${stdenv.shellDryRun} "$target"
        ${shellcheck}/bin/shellcheck --severity=style "$target"
      '';
      meta.mainProgram = name;
    };

  packages' = with pkgs; [
    llvmPackages_latest.clang-tools
    llvmPackages_latest.lld
    ps
    coreutils
    findutils
    parallel
    curl
    jq
    process-compose
    watchexec'
    pigz
    brotli
    zstd
    b3sum
    nixfmt-rfc-style
    # Python:
    python'
    uv
    ruff
    gettext
    protobuf_31
    cmake
    libxml2.dev
    openssl.dev
    # Frontend:
    bun
    biome
    nodejs-slim
    # Services:
    (postgresql_17_jit.withPackages (ps: [
      ps.timescaledb-apache
      ps.postgis
      ps.h3-pg
      ps.pg_hint_plan
    ]))
    timescaledb-parallel-copy
    mailpit

    # Scripts:
    # -- Cython
    (makeScript "cython-build" ''
      files=()
      declare -A BLACKLIST

      # Reason: Unsupported PEP-654 Exception Groups
      # https://github.com/cython/cython/issues/4993
      BLACKLIST["app/services/optimistic_diff/__init__.py"]=1

      # Reason: Lambda default arguments fail with embedsignature=True
      # https://github.com/cython/cython/issues/6880
      BLACKLIST["app/lib/pydantic_settings_integration.py"]=1

      DIRS=(
        "app/exceptions" "app/exceptions06" "app/format" "app/lib"
        "app/middlewares" "app/responses" "app/services"
        "app/queries" "app/validators"
      )
      for dir in "''${DIRS[@]}"; do
        for file in "$dir"/**/*.py; do
          if [ -f "$file" ] && [ -z "''${BLACKLIST[$file]:-}" ]; then
            files+=("$file")
          fi
        done
      done

      EXTRA_PATHS=(
        "app/db.py" "app/utils.py"
        "app/models/element.py" "app/models/scope.py" "app/models/tags_format.py"
        "scripts/preload_convert.py" "scripts/replication_download.py"
        "scripts/replication_generate.py"
      )
      for file in "''${EXTRA_PATHS[@]}"; do
        if [ -f "$file" ] && [ -z "''${BLACKLIST[$file]:-}" ]; then
          files+=("$file")
        fi
      done

      echo "Found ''${#files[@]} source files"

      CFLAGS="$(python-config --cflags) $CFLAGS \
        -shared -fPIC \
        -DCYTHON_PROFILE=1 \
        -DCYTHON_USE_SYS_MONITORING=0"
      export CFLAGS

      LDFLAGS="$(python-config --ldflags) $LDFLAGS"
      export LDFLAGS

      _SUFFIX=$(python-config --extension-suffix)
      export _SUFFIX

      process_file() {
        pyfile="$1"
        module_name="''${pyfile%.py}"  # Remove .py extension
        module_name="''${module_name//\//.}"  # Replace '/' with '.'
        c_file="''${pyfile%.py}.c"
        so_file="''${pyfile%.py}$_SUFFIX"

        # Skip unchanged files
        if [ "$so_file" -nt "$pyfile" ]; then
          return 0
        fi

        (set -x; cython -3 \
          --annotate \
          --directive overflowcheck=True,embedsignature=True,profile=True \
          --module-name "$module_name" \
          "$pyfile" -o "$c_file")

        # shellcheck disable=SC2086
        (set -x; $CC $CFLAGS "$c_file" -o "$so_file" $LDFLAGS)
      }
      export -f process_file

      parallel --will-cite \
        --bar --eta \
        process_file ::: "''${files[@]}"
    '')
    (makeScript "cython-build-fast" ''
      CFLAGS="$CFLAGS \
        -O0 \
        -fno-lto \
        -fno-sanitize=all" \
      LDFLAGS="$LDFLAGS \
        -fno-lto \
        -fno-sanitize=all" \
      cython-build
    '')
    (makeScript "cython-clean" ''
      rm -rf build/
      find app scripts \
        -type f \
        \( -name '*.c' -o -name '*.html' -o -name '*.so' \) \
        -not \
        \( -path 'app/static/*' -o -path 'app/views/*' \) \
        -delete
    '')
    (makeScript "watch-cython" "exec watchexec -o queue -w app --exts py cython-build-fast")

    # -- CSS
    (makeScript "css-pipeline" ''
      src=app/views
      dst=app/static/css
      rm -f "$dst"/*.{css,map}{,.br,.zst}

      mappings=()
      for f in main id rapid embed; do
        mappings+=("$src/$f.scss:$dst/$f.css")
      done
      bun run sass \
        --quiet-deps \
        --silence-deprecation=import \
        --style compressed \
        --load-path node_modules \
        --no-source-map \
        "''${mappings[@]}"

      bun run postcss \
        "$dst"/*.css \
        --use autoprefixer \
        --replace \
        --no-map

      for file in "$dst"/*.css; do
        hash=$(b3sum --no-names --length=6 "$file")
        new_file="''${file%.css}.$hash.css"
        mv "$file" "$new_file"
        echo "  $new_file"
      done
    '')
    (makeScript "watch-css" "exec watchexec -o queue -w app/views -e scss css-pipeline")

    # -- JavaScript
    (makeScript "js-pipeline" ''
      src=app/views
      dst=app/static/js
      tmp="$dst/_generated"
      mkdir -p "$tmp"
      rm -f "$dst"/*.{js,map}{,.br,.zst}

      bun run babel \
        --extensions ".js,.ts" \
        --copy-files \
        --no-copy-ignored \
        --out-dir "$tmp" \
        "$src"

      bun build \
        --entry-naming="[dir]/[name].[hash].[ext]" \
        --minify \
        --sourcemap=linked \
        --outdir "$dst" \
        "$tmp"/{main,main-sync,id,rapid,embed,test-site}.js
    '')
    (makeScript "watch-js" "exec watchexec -o queue -w app/views -e ts js-pipeline")

    # -- Static
    (makeScript "static-img-clean" "rm -rf app/static/img/element/_generated")
    (makeScript "static-img-pipeline" "python scripts/rasterize.py static-img-pipeline")
    (makeScript "static-precompress-clean" "static-precompress clean")
    (makeScript "static-precompress" ''
      process_file() {
        file="$1"
        mode="$2"

        process_file_inner() {
          dest="$file.$extension"
          if [ "$mode" = "clean" ]; then
            rm -f "$dest"
            return
          fi
          if [ ! -f "$dest" ] || [ "$dest" -ot "$file" ]; then
            tmpfile=$(mktemp -t "$(basename "$dest").XXXXXXXXXX")
            $compressor "''${args[@]}" "$file" -o "$tmpfile"
            touch --reference "$file" "$tmpfile"
            mv -f "$tmpfile" "$dest"
          fi
        }

        extension="zst"
        compressor="zstd"
        args=(--force --ultra -22 --single-thread --quiet)
        process_file_inner

        extension="br"
        compressor="brotli"
        args=(--force --best)
        process_file_inner
      }
      export -f process_file

      find  \
        "app/static" \
        "config/locale/i18next" \
        "node_modules/iD/dist" \
        "node_modules/@rapideditor/rapid/dist" \
        -type f \
        -not -path "app/static/js/_generated/*" \
        -not -path "node_modules/@rapideditor/rapid/dist/examples/*" \
        -not -name "*.xcf" \
        -not -name "*.gif" \
        -not -name "*.jpg" \
        -not -name "*.jpeg" \
        -not -name "*.png" \
        -not -name "*.webp" \
        -not -name "*.ts" \
        -not -name "*.scss" \
        -not -name "*.br" \
        -not -name "*.zst" \
        -size +499c \
        -printf "%s\t%p\0"  \
      | sort -z --numeric-sort --reverse \
      | cut -z -f2- \
      | parallel --will-cite --null \
        --bar --eta \
        --halt now,fail=1 \
        process_file {} "$@"
    '')

    # -- Locale
    (makeScript "locale-clean" "rm -rf config/locale/*/")
    (makeScript "locale-download" "python scripts/locale_download.py")
    (makeScript "locale-postprocess" ''python scripts/locale_postprocess.py "$@"'')
    (makeScript "locale-make-i18next" "python scripts/locale_make_i18next.py")
    (makeScript "locale-make-gnu" "python scripts/locale_make_gnu.py")
    (makeScript "locale-pipeline" ''
      locale-postprocess
      locale-make-i18next &
      locale-make-gnu &
      wait
    '')
    (makeScript "locale-pipeline-with-download" ''
      set -x
      locale-download
      locale-pipeline
    '')
    (makeScript "watch-locale" "exec watchexec -o queue -w config/locale/extra_en.yaml locale-pipeline")

    # -- Protobuf
    (makeScript "proto-pipeline" ''
      mkdir -p app/views/lib/proto
      protoc \
        -I app/models/proto \
        --plugin=node_modules/.bin/protoc-gen-es \
        --es_out app/views/lib/proto \
        --es_opt target=ts \
        --python_out app/models/proto \
        --pyi_out app/models/proto \
        app/models/proto/*.proto
      rm app/views/lib/proto/server*
    '')
    (makeScript "watch-proto" "exec watchexec -o queue -w app/models/proto --exts proto proto-pipeline")

    # -- Services
    (makeScript "dev-start" ''
      if [ -S "$PC_SOCKET_PATH" ]; then
        echo "Services are already running"
        exit 0
      fi

      if [ ! -f data/postgres/PG_VERSION ]; then
        initdb -D data/postgres \
          --no-instructions \
          --locale-provider=icu \
          --icu-locale=und \
          --no-locale \
          --text-search-config=pg_catalog.simple \
          --auth=trust \
          --username=postgres
      fi

      mkdir -p data/mailpit data/postgres_unix data/pcompose
      echo "Services starting..."
      process-compose up -U --detached -f "''${1:-${processComposeConf}}" >/dev/null
      process-compose project is-ready -U --wait

      process-compose list -U | while read -r name; do
        if [ -z "$name" ] || [ "$name" = "mailpit" ]; then
          continue
        fi

        echo -n "Waiting for $name..."
        while [ "$(process-compose process get "$name" -U --output json | jq -r '.[0].is_ready')" != "Ready" ]; do
          sleep 1
          echo -n "."
        done
        echo " ready"
      done

      echo "Services started"
    '')
    (makeScript "dev-stop" ''
      if [ -S "$PC_SOCKET_PATH" ]; then
        echo "Services stopping..."
        process-compose down -U
        echo "Services stopped"
      else
        echo "Services are not running"
      fi
    '')
    (makeScript "dev-restart" ''
      set -x
      dev-stop
      dev-start
    '')
    (makeScript "dev-clean" ''
      dev-stop
      rm -rf data/postgres/ data/postgres_unix/
    '')
    (makeScript "dev-logs-postgres" "tail -f data/pcompose/postgres.log")
    (makeScript "dev-logs-global" "tail -f data/pcompose/global.log")

    # -- Preload
    (makeScript "preload-clean" "rm -rf data/preload/")
    (makeScript "preload-convert" ''
      python scripts/preload_convert.py "$@"
      for file in data/preload/*.csv; do
        zstd \
          --rm \
          --force -19 \
          --threads "$(( $(nproc) * 2 ))" \
          "$file"
      done
    '')
    (makeScript "preload-upload" ''
      read -rp "Preload dataset name: " dataset
      if [ "$dataset" != "mazowieckie" ]; then
        echo "Invalid dataset name, must be one of: mazowieckie"
        exit 1
      fi
      mkdir -p "data/preload/$dataset"
      cp --archive --link --force data/preload/*.csv.zst "data/preload/$dataset/"
      echo "Computing checksums file"
      b3sum "data/preload/$dataset/"*.csv.zst > "data/preload/$dataset/checksums.b3"
      rsync \
        --verbose \
        --archive \
        --checksum \
        --whole-file \
        --delay-updates \
        --human-readable \
        --progress \
        "data/preload/$dataset/"*.csv.zst \
        "data/preload/$dataset/checksums.b3" \
        edge:"/var/www/files.monicz.dev/openstreetmap-ng/preload/$dataset/"
    '')
    (makeScript "preload-download" ''
      echo "Available preload datasets:"
      echo "  * mazowieckie: Masovian Voivodeship; 1.6 GB download; 60 GB disk space; 15-30 minutes"
      read -rp "Preload dataset name [default: mazowieckie]: " dataset
      dataset="''${dataset:-mazowieckie}"
      if [ "$dataset" != "mazowieckie" ]; then
        echo "Invalid dataset name, must be one of: mazowieckie"
        exit 1
      fi

      echo "Checking for preload data updates"
      remote_check_url="https://files.monicz.dev/openstreetmap-ng/preload/$dataset/checksums.b3"
      remote_checksums=$(curl -sSL "$remote_check_url")
      names=$(grep -Po '[^/]+(?=\.csv\.zst)' <<< "$remote_checksums")

      mkdir -p "data/preload/$dataset"
      for name in $names; do
        remote_url="https://files.monicz.dev/openstreetmap-ng/preload/$dataset/$name.csv.zst"
        local_file="data/preload/$dataset/$name.csv.zst"
        local_check_file="data/preload/$dataset/$name.csv.zst.b3"

        # recompute checksum if missing but file exists
        if [ -f "$local_file" ] && [ ! -f "$local_check_file" ]; then
          b3sum --no-names "$local_file" > "$local_check_file"
        fi

        # compare with remote checksum
        remote_checksum=$(grep -F "$local_file" <<< "$remote_checksums" | cut -d' ' -f1)
        local_checksum=$(cat "$local_check_file" 2>/dev/null || echo "x")
        if [ "$remote_checksum" = "$local_checksum" ]; then
          echo "File $local_file is up to date"
          continue
        fi

        echo "Downloading $name preload data"
        curl -L "$remote_url" -o "$local_file"

        # recompute checksum
        local_checksum=$(b3sum --no-names "$local_file")
        echo "$local_checksum" > "$local_check_file"
        if [ "$remote_checksum" != "$local_checksum" ]; then
          echo "[!] Checksum mismatch for $local_file"
          echo "[!] Please retry this command after a few minutes"
          exit 1
        fi
      done
      cp --archive --link "data/preload/$dataset/"*.csv.zst data/preload/
    '')
    (makeScript "_db-load" ''
      set -x
      : Restarting database in fast-ingest mode :
      dev-stop
      dev-start "${processComposeFastIngestConf}"
      python scripts/db_load.py -m "$1"
      : Restarting database in normal mode :
      dev-stop
      dev-start
    '')
    (makeScript "preload-load" "_db-load preload")
    (makeScript "preload-pipeline" ''
      set -x
      preload-download
      preload-load
    '')
    (makeScript "replication-download" "python scripts/replication_download.py")
    (makeScript "replication-convert" ''python scripts/replication_convert.py "$@"'')
    (makeScript "replication-load" "_db-load replication")
    (makeScript "replication-generate" ''python scripts/replication_generate.py "$@"'')

    # -- Testing
    (makeScript "run-tests" ''
      if [ ! -S "$PC_SOCKET_PATH" ]; then
        echo "NOTICE: Services are not running"
        echo "NOTICE: Run 'dev-start' before executing tests"
        exit 1
      fi

      term_output=0
      args=(
        --verbose
        --no-header
        --randomly-seed="$(date +%s)"
      )

      for arg in "$@"; do
        case "$arg" in
          --term)
            term_output=1
            ;;
          *)
            args+=("$arg")
            ;;
        esac
      done

      set +e
      (set -x; python -m coverage run -m pytest "''${args[@]}")
      result=$?
      set -e

      if [ "$term_output" = "1" ]; then
        python -m coverage report --skip-covered
      else
        python -m coverage xml --quiet
      fi
      python -m coverage erase
      exit $result
    '')
    (makeScript "watch-tests" "exec watchexec -w app -w tests --exts py run-tests")

    # -- Misc
    (makeScript "run" (
      if isDevelopment then
        ''
          python -m uvicorn app.main:main \
            --reload \
            --reload-include "*.mo" \
            --reload-exclude scripts \
            --reload-exclude tests \
            --reload-exclude typings
        ''
      else
        ''
          python -m gunicorn app.main:main \
            --bind 127.0.0.1:${toString gunicornPort} \
            --workers ${toString gunicornWorkers} \
            --worker-class uvicorn.workers.UvicornWorker \
            --max-requests 10000 \
            --max-requests-jitter 1000 \
            --graceful-timeout 5 \
            --keep-alive 300 \
            --access-logfile -
        ''
    ))
    (makeScript "format" ''
      set +e
      ruff check . --fix
      pre-commit run -c ${preCommitConf} --all-files
    '')
    (makeScript "pyright" "bunx basedpyright")
    (makeScript "feature-icons-popular-update" "python scripts/feature_icons_popular_update.py")
    (makeScript "timezone-bbox-update" "python scripts/timezone_bbox_update.py")
    (makeScript "wiki-pages-update" "python scripts/wiki_pages_update.py")
    (makeScript "vector-styles-update" ''
      dir=app/views/lib/vector-styles
      mkdir -p "$dir"
      styles=(
        "liberty+https://tiles.openfreemap.org/styles/liberty"
      )
      for style in "''${styles[@]}"; do
        name="''${style%%+*}"
        url="''${style#*+}"
        file="$dir/$name.json"
        echo "Updating $name vector style"
        curl -sSL --compressed "$url" | jq --sort-keys . > "$file"
      done
    '')
    (makeScript "open-mailpit" "python -m webbrowser http://127.0.0.1:49566")
    (makeScript "open-app" "python -m webbrowser http://127.0.0.1:8000")
    (makeScript "patch-venv-bin" ''
      find .venv/bin -maxdepth 1 -type f -executable | while read -r script; do
        if ! head -n 1 "$script" | grep -q "\.venv/bin/python"; then continue; fi

        module_name=$(grep -Po "(?<=^from )\S+" "$script")
        if [ -z "$module_name" ]; then
          echo "Warning: Could not extract module name from $script"
          continue
        fi

        temp_file=$(mktemp)
        cat > "$temp_file" << EOF
      #!${runtimeShell}
      exec python -m $module_name "\$@"
      EOF
        chmod --reference="$script" "$temp_file"
        mv "$temp_file" "$script"

        echo "Patched $script"
      done
    '')
    (makeScript "nixpkgs-update" ''
      hash=$(
        curl -sSL \
          https://prometheus.nixos.org/api/v1/query \
          -d 'query=channel_revision{channel="nixpkgs-unstable"}' \
        | jq -r ".data.result[0].metric.revision")
      sed -i "s|nixpkgs/archive/[0-9a-f]\\{40\\}|nixpkgs/archive/$hash|" shell.nix
      echo "Nixpkgs updated to $hash"
    '')
  ];

  shell' =
    with pkgs;
    ''
      export TZ=UTC
      export NIX_ENFORCE_NO_NATIVE=0
      export NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      export SSL_CERT_FILE=$NIX_SSL_CERT_FILE
      export PROC_COMP_CONFIG=data/pcompose
      export PC_DISABLE_DOTENV=1
      export PC_LOG_FILE=data/pcompose/internal.log
      export PC_SOCKET_PATH="${projectDir}/data/pcompose/pcompose.sock"
      export PATH="$PATH:${gitMinimal}/bin"
      export PYTHONNOUSERSITE=1
      export PYTHONPATH="${projectDir}"
      export COVERAGE_CORE=sysmon

      export CFLAGS="$CFLAGS \
        -pipe -g ${if isDevelopment then "-Og" else "-O3"} \
        -march=''${CMARCH:-native} \
        -mtune=''${CMTUNE:-native} \
        -funsafe-math-optimizations \
        -fvisibility=hidden \
        -flto=thin \
        -fno-plt"

      export LDFLAGS="$LDFLAGS \
        -flto=thin \
        -fuse-ld=lld \
        ${if isDevelopment then "" else "-Wl,--strip-all"}"

      en_yaml_path="${projectDir}/config/locale/download/en.yaml"
      en_yaml_sym_path="${projectDir}/config/locale/en.yaml"
      current_en_yaml=$(readlink -e "$en_yaml_sym_path" || echo "")
      if [ "$current_en_yaml" != "$en_yaml_path" ]; then
        echo "Creating convenience symlink for en.yaml"
        ln -s "$en_yaml_path" "$en_yaml_sym_path"
      fi

      current_python=$(readlink -e .venv/bin/python || echo "")
      current_python=''${current_python%/bin/*}
      [ "$current_python" != "${python'}" ] && rm -rf .venv/

      echo "Installing Python dependencies"
      export UV_PYTHON="${python'}/bin/python"
      uv sync --frozen
      [ -n "$(find speedup -newer .venv/lib/python3.13/site-packages/speedup -print -quit 2>/dev/null)" ] && \
        uv add ./speedup --reinstall-package speedup

      echo "Installing Bun dependencies"
      export DO_NOT_TRACK=1
      bun install --frozen-lockfile

      echo "Activating Python virtual environment"
      source .venv/bin/activate
    ''
    + lib.optionalString stdenv.isDarwin ''
      patch-venv-bin &
    ''
    + ''

      if [ -d .git ]; then
        echo "Installing pre-commit hooks"
        pre-commit install -c ${preCommitConf} --overwrite
        cp --force --symbolic-link ${preCommitHook}/bin/pre-commit-hook .git/hooks/pre-commit
      fi

    ''
    + lib.optionalString isDevelopment ''
      export ENV=dev
      export SECRET=development-secret
      export APP_URL=http://127.0.0.1:8000
      export NOMINATIM_URL=https://nominatim.monicz.dev
      export GRAPHHOPPER_API_KEY=e6d61235-3e37-4290-91a7-d7be9e5a8909
      export FACEBOOK_OAUTH_PUBLIC=1538918736889845
      export FACEBOOK_OAUTH_SECRET=4090c8e1f08a93af65c6d6cc56350f4b
      export GITHUB_OAUTH_PUBLIC=Ov23lidLgxluuWuo0PNn
      export GITHUB_OAUTH_SECRET=4ed29823ee9d975e9f42a14e5c3d4b8293041cda
      export GOOGLE_OAUTH_PUBLIC=329628600169-6du7d20fo0poong0aqttuikstq97bten.apps.googleusercontent.com
      export GOOGLE_OAUTH_SECRET=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
      export MICROSOFT_OAUTH_PUBLIC=db54bdb3-08af-481b-9641-39f49065b640
      export WIKIMEDIA_OAUTH_PUBLIC=2f7fe9e2825acc816d1e1103d203e8ec
      export WIKIMEDIA_OAUTH_SECRET=d07aaeabb5f7a5de76e3d667db3dfe0b2a5abf11
      export LEGACY_HIGH_PRECISION_TIME=1
      export LEGACY_GEOM_SKIP_MISSING_NODES=1
    ''
    + lib.optionalString enableMailpit ''
      export SMTP_HOST=127.0.0.1
      export SMTP_PORT=49565
      export SMTP_USER=mail@openstreetmap.org
      export SMTP_PASS=anything
    ''
    + ''
      export DUCKDB_MEMORY_LIMIT=${toString (hostMemoryMb / 2)}MB

      if [ -f .env ]; then
        echo "Loading .env file"
        set -o allexport
        source .env set
        set +o allexport
      else
        echo "Skipped loading .env file (not found)"
      fi

      echo "Running [static-img-pipeline]"
      static-img-pipeline &
      echo "Running [proto-pipeline]"
      proto-pipeline &
    ''
    + lib.optionalString (!isDevelopment) ''
      echo "Running [locale-pipeline]"
      locale-pipeline &
      echo "Running [css-pipeline]"
      css-pipeline &
      wait
      echo "Running [js-pipeline]"
      js-pipeline &
    ''
    + ''
      wait
    '';
in
with pkgs;
mkShell.override
  {
    stdenv = if stdenv.isDarwin then stdenv else llvmPackages_latest.stdenv;
  }
  {
    packages = packages';
    shellHook = shell';
  }
