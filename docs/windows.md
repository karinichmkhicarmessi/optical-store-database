# Запуск на Windows

Откройте папку репозитория в PowerShell. Пример использует PostgreSQL 18 с локальным адресом `127.0.0.1`, портом `5432` и пользователем `postgres`. Если подключение DBeaver использует другие параметры, подставьте их в `$pgConnection`. При запросе введите пароль в PowerShell. Символы при вводе скрыты.

```powershell
$pg = 'C:\Program Files\PostgreSQL\18\bin'
$pgConnection = @('-h', '127.0.0.1', '-p', '5432', '-U', 'postgres')
chcp.com 65001
```

Запускайте следующие команды по одной. Если какая-либо завершилась ошибкой, сначала устраните её.

```powershell
& "$pg\createdb.exe" @pgConnection -T template0 optical_store_demo
& "$pg\psql.exe" @pgConnection -X -d optical_store_demo -v ON_ERROR_STOP=1 -1 -f sql/01_schema.sql
& "$pg\psql.exe" @pgConnection -X -d optical_store_demo -v ON_ERROR_STOP=1 -f sql/02_demo_data.sql
& "$pg\psql.exe" @pgConnection -X -d optical_store_demo -v ON_ERROR_STOP=1 -f sql/03_example_queries.sql
```

В DBeaver выделите папку **«Базы данных»** в подключении к тому же локальному серверу и нажмите **F5**. В списке появится `optical_store_demo`. Таблицы находятся в схеме `public`.

## Основные тесты

Для тестов создайте другую пустую базу и загрузите только схему.

```powershell
& "$pg\createdb.exe" @pgConnection -T template0 optical_store_test
& "$pg\psql.exe" @pgConnection -X -d optical_store_test -v ON_ERROR_STOP=1 -1 -f sql/01_schema.sql
& "$pg\psql.exe" @pgConnection -X -d optical_store_test -f tests/01_integrity.sql
```

Ожидаемый итог — `PASS | 194`. Строка `ROLLBACK` после отчёта означает, что тестовые записи были удалены откатом транзакции. Схема остаётся доступной.
