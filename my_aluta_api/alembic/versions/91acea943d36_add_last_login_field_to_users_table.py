# Revision ID: 91acea943d36
# Revisions: be6d847d9f46
# Create Date: 2025-05-06 17:18:41.820456

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '91acea943d36'
down_revision: Union[str, None] = 'be6d847d9f46'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def upgrade() -> None:
    """Upgrade schema."""
    # Add last_login column with timezone support
    op.add_column('users', sa.Column('last_login', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now()))
    
    # Ensure last_seen stays with timezone (do not alter it)
    op.alter_column('users', 'last_seen',
                   existing_type=postgresql.TIMESTAMP(timezone=True),
                   type_=postgresql.TIMESTAMP(timezone=True),
                   existing_nullable=True)

def downgrade() -> None:
    """Downgrade schema."""
    # Revert last_seen column to have timezone info (no change needed as it already has timezone)
    op.alter_column('users', 'last_seen',
                   existing_type=postgresql.TIMESTAMP(timezone=True),
                   type_=postgresql.TIMESTAMP(timezone=True),
                   existing_nullable=True)
    
    # Drop last_login column
    op.drop_column('users', 'last_login')
