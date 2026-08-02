from logging.config import fileConfig
import os
import sys

from sqlalchemy import engine_from_config, pool
from alembic import context

# --------------------------
# Load environment variables
# --------------------------
from dotenv import load_dotenv
load_dotenv()

# --------------------------
# Add project path to sys.path
# --------------------------
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# --------------------------
# Import Base from your models
# --------------------------
import models  # if all models are loaded within that file

# --------------------------
# Alembic config setup
# --------------------------
config = context.config

# Use environment variable for DB URL
db_url = os.getenv("DATABASE_URL")
if db_url:
    config.set_main_option("sqlalchemy.url", db_url)

# Configure logging
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Metadata for autogenerate support
target_metadata = models.Base.metadata

# --------------------------
# Offline migration
# --------------------------
def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()

# --------------------------
# Online migration
# --------------------------
def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""
    connectable = engine_from_config(
        config.get_section(config.config_ini_section),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata
        )

        with context.begin_transaction():
            context.run_migrations()

# --------------------------
# Entry point
# --------------------------
if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
