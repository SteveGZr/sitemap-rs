{ pkgs }:

let
  src = pkgs.lib.cleanSource ./.;

  # Wir erzeugen die Dummy-Daten mit Nix, damit sie ge-cache-t werden und nicht
  # unnötigerweise im Working-Directory liegen.
  dummy-data = pkgs.runCommand "atlas-dummy-data" {} ''
    mkdir $out
  '';
in rec {
  # `atlas-mysql` verhält sich wie `mysql`, verbindet sich aber standardmäßig
  # auf die durch Umgebungsvariablen festgelegte Atlas-Datenbank. Wird
  # vorrangig in Tests verwendet.
  atlas-mysql = pkgs.writeShellApplication {
    name = "atlas-mysql";
    runtimeInputs = [ pkgs.mysql ];
    text = ''
      MYSQL_PWD="$DATABASE_PASSWORD" mysql -h "$DATABASE_HOST" \
            -P "$DATABASE_PORT" \
            -u "$DATABASE_USERNAME" \
            "$DATABASE_NAME" \
            "$@"
    '';
  };

  # Die einzige Stelle, an der wir DATABASE_URL aus den anderen
  # DATABASE_*-Umgebungsvariablen setzen. D.h. alle Prozesse, die DATABASE_URL
  # benötigen, sollten mit diesem Wrapper gestartet werden.
  with-database-url = pkgs.writeShellApplication {
    name = "with-database-url";
    text = ''
      export DATABASE_URL=mysql://$DATABASE_USERNAME:$DATABASE_PASSWORD@$DATABASE_HOST:$DATABASE_PORT/$DATABASE_NAME
      exec "$@"
    '';
  };

  atlas-recreate-db = pkgs.writeShellApplication {
    name = "atlas-recreate-db";
    runtimeInputs = [ pkgs.mysql atlas-mysql ];
    text = ''
      function mysql_ {
          MYSQL_PWD="$DATABASE_PASSWORD" \
                mysql -h "$DATABASE_HOST" -P "$DATABASE_PORT" \
                -u "$DATABASE_USERNAME"
      }

      echo -n "Dropping database '$DATABASE_NAME'... "
      echo "DROP DATABASE IF EXISTS $DATABASE_NAME" | mysql_
      echo "done."

      echo -n "Creating database '$DATABASE_NAME'... "
      echo "
        CREATE DATABASE $DATABASE_NAME
          DEFAULT CHARACTER SET utf8
          DEFAULT COLLATE utf8_general_ci;
      " | mysql_
      echo "done."
    '';
  };

  atlas-create-tables-and-routines = pkgs.writeShellApplication {
    name = "atlas-create-tables-and-routines";
    runtimeInputs = [ atlas-mysql atlas-recreate-db-routines ];
    text = ''
      echo -n "Creating tables... "
      atlas-mysql < "${src}/create_tables.sql"
      echo "done."

      atlas-recreate-db-routines
    '';
  };

  atlas-recreate-db-routines = pkgs.writeShellApplication {
    name = "atlas-recreate-db-routines";
    runtimeInputs = [ atlas-mysql ];
    text = ''
      echo -n "(Re)creating routines... "
      cat "${src}/functions/"*.sql \
          "${src}/stored_procedures/"*.sql \
          "${src}/triggers/"*.sql \
          | atlas-mysql
      echo "done."
    '';
  };

  atlas-migrate = pkgs.writeShellApplication rec {
    name = "atlas-migrate";
    runtimeInputs = [ atlas-mysql atlas-recreate-db-routines ];
    text = ''
      if [[ "$#" -lt 1 ]]; then
        echo "usage:   ${name} FILENAME [FILENAME...]"
        echo "example: ${name} 0004_drop_is_weak.sql"
        exit 1
      fi

      for filename in "$@"; do
        echo "Executing $filename..."
        atlas-mysql < "${src}/migrations/$filename"
        echo "done."
      done
    '';
  };

  atlas-recreate-db-users = pkgs.writeShellApplication {
    name = "atlas-recreate-db-users";
    runtimeInputs = [ pkgs.mysql ];
    text = ''
      mysql_root() {
        mysql -h "$DATABASE_HOST" \
              -P "$DATABASE_PORT" \
              -u root
      }

      echo -n "Creating user atlas... "
      echo "
        DROP USER IF EXISTS atlas;
        CREATE USER atlas@'%' IDENTIFIED BY 'dev';
        GRANT ALL ON atlas.* TO atlas@'%';
      " | mysql_root
      echo "done."

      echo -n "Creating user atlas_testing... "
      echo "
        DROP USER IF EXISTS atlas_testing;
        CREATE USER atlas_testing@'%' IDENTIFIED BY 'dev';
        GRANT ALL ON atlas_testing.* TO atlas_testing@'%';

        -- Für Hard-Resets:
        GRANT SELECT ON atlas.* TO atlas_testing@'%';
        GRANT TRIGGER ON atlas.* TO atlas_testing@'%';
        GRANT SHOW_ROUTINE ON *.* TO atlas_testing@'%';
        GRANT RELOAD ON *.* TO atlas_testing@'%';
      " | mysql_root
      echo "done."
    '';
  };

  atlas-insert-dummy-data = pkgs.writeShellApplication {
    name = "atlas-insert-dummy-data";
    runtimeInputs = [ atlas-mysql ];
    text = ''
      for sql in "${dummy-data}/"*.sql; do
        echo -n "Importing $sql... "
        atlas-mysql < "$sql"
        echo "done."
      done
    '';
  };

  # Ein kleiner Wrapper, um das angeführte Shell-Kommando mit der
  # Test-Datenbank auszuführen, z.B. `with-test-db just reset-db`.
  with-test-db = pkgs.writeShellApplication {
    name = "with-test-db";
    runtimeInputs = [ with-database-url ];
    text = ''
      export DATABASE_NAME=atlas_testing
      export DATABASE_USERNAME=atlas_testing
      exec with-database-url "$@"
    '';
  };

  atlas-update-live-db-dump = pkgs.writeShellApplication rec {
    name = "atlas-update-live-db-dump";
    # XXX: kubectl sollte auch hier stehen. Der Plan ist, das an zentraler
    # Stelle über das puzzleyou-flake zu installieren, weil das auch noch
    # spezielle Plugins braucht.
    runtimeInputs = [ pkgs.mysql pkgs.netcat atlas-mysqldump ];
    text = ''
      if [[ "$#" -lt 1 ]]; then
         echo "usage: ${name} DUMP_PATH"
         exit 1
      fi

      dump_path="$1"

      if [[ -n $(find . -iname "$dump_path" -mtime -1) ]]; then
          echo "$dump_path exists and is less than a day old."
          echo "I will not create a new dump. If you want to, move $dump_path."
          exit 0
      fi

      port=3316
      kubectl port-forward -n cloudsql pod/mysql8-proxy $port:3306 > /dev/null &
      proxy_pid=$!
      trap 'kill $proxy_pid' SIGINT SIGTERM EXIT

      echo -n "Wait until port forwarding to database is ready... "
      timeout 30 sh -c "until nc -z localhost $port >/dev/null 2>&1; do sleep 1; done"
      echo "done."

      database_settings=$(kubectl -n atlas get secret database-settings -o yaml)

      function get_database_setting() {
          name="$1"
          echo "$database_settings" \
              | grep -Po "(?<=$name: ).*" \
              | base64 -d
      }

      username=$(get_database_setting DATABASE_USERNAME)
      password=$(get_database_setting DATABASE_PASSWORD)
      database=$(get_database_setting DATABASE_NAME)

      echo -n "Dumping live database... "
      DATABASE_HOST=127.0.0.1 \
          DATABASE_PORT="$port" \
          DATABASE_USERNAME="$username" \
          DATABASE_PASSWORD="$password" \
          DATABASE_NAME="$database" \
          atlas-mysqldump \
          | gzip > "$dump_path"
      echo "done."
    '';
  };

  atlas-mysqldump = pkgs.writeShellApplication {
    name = "atlas-mysqldump";
    runtimeInputs = [ pkgs.mysql ];
    text = ''
      # shellcheck disable=SC2016
      MYSQL_PWD="$DATABASE_PASSWORD" \
          mysqldump -h "$DATABASE_HOST" -P "$DATABASE_PORT" -u "$DATABASE_USERNAME" \
          --set-gtid-purged=OFF \
          --single-transaction \
          --no-tablespaces \
          --triggers \
          --routines \
          "$DATABASE_NAME" \
          | sed 's/ DEFINER=`.*`@`%`//'
    '';
  };

  atlas-hard-reset = pkgs.writeShellApplication rec {
    name = "atlas-hard-reset";
    runtimeInputs = [ atlas-mysqldump atlas-import-db-dump ];
    text = ''
      if [[ "$DATABASE_NAME" != *"_testing" ]]; then
        echo "${name} can only be used to reset testing databases."
        echo "You are trying to reset database '$DATABASE_NAME'!"
        exit 1
      fi

      # Die Quell-Datenbank ist die aktuelle Datenbank ohne den Suffix "_testing".
      # Es besteht hier wenig Risiko, dass diese Konvention mal zu Problemen
      # führt. Selbst wenn die falsche DB gewählt wird, müssen zum einen Berechtigungen
      # auf dieser gesetzt sein und zum anderen greifen wir nur lesend auf diese DB zu.
      source_db_name=''${DATABASE_NAME%_testing}

      dump_path="/tmp/hard-reset-dump.sql.gz"

      echo -n "Dumping database $source_db_name... "
      DATABASE_NAME="$source_db_name" atlas-mysqldump \
          | gzip > "$dump_path"
      echo "done."

      atlas-import-db-dump "$dump_path"

      rm "$dump_path"
    '';
  };

  atlas-import-db-dump = pkgs.writeShellApplication rec {
    name = "atlas-import-db-dump";
    runtimeInputs = [ atlas-mysql atlas-recreate-db ];
    text = ''
      if [[ "$#" -lt 1 ]]; then
         echo "usage: ${name} DUMP_PATH"
         exit 1
      fi

      dump_path="$1"

      atlas-recreate-db

      echo -n "Importing dump... "
      zcat "$dump_path" | atlas-mysql
      echo "done."
    '';
  };

  atlas-watch-sql-files = pkgs.writeShellApplication {
    name = "atlas-watch-sql-files";
    # XXX: Das ist ein bisschen hacky, weil das Skript dann unter
    # Nicht-Linux-Systemen existiert, aber einfach nicht funktioniert. Ich
    # wollte aber alle Skripte in *ein* Attribute-Set schreiben und nicht wie
    # vorher manche als let-Binding und manche direkt im Attribute-Set. Können
    # wir lösen, wenn es relevant wird.
    runtimeInputs = [ atlas-mysql ] ++
                    (pkgs.lib.optionals pkgs.stdenv.isLinux
                      [ pkgs.inotify-tools ]);
    text = ''
      sql_root="$1"
      test_script="$2"

      # Test direkt einmal ausführen, auch ohne Änderungen an den Dateien.
      $test_script || true

      # Wir müssen hier `close_write` statt `modify` verwenden, da inotifywait
      # sonst versucht Dateien während des Schreibvorgangs auszuführen. Das
      # führt dann zu Fehlermeldungen wie "/usr/bin/env: bad interpreter:
      # Text file busy"
      inotifywait -e create,close_write,moved_to -m \
                  "$sql_root/functions" \
                  "$sql_root/stored_procedures" \
                  "$sql_root/triggers" \
                  "$test_script" \
          | while read -r directory _ filename; do
              if [[ "$filename" == .* ]]; then
                  continue
              fi

              path="$directory$filename"
              case $path in
                  *.sql)
                      echo -e "\n*** mysql < $path"
                      atlas-mysql < "$path" || continue
                      echo -e "\n*** $test_script"
                      $test_script || true
                      ;;
                  "$test_script")
                      echo -e "\n*** $test_script"
                      $test_script || true
                      ;;
              esac
          done
    '';
  };
}
