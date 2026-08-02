# Revision ID: 46a4136ccc90
# Revisions: e9f43f239814
# Create Date: 2025-04-01 22:30:25.413818

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '46a4136ccc90'
down_revision: Union[str, None] = 'e9f43f239814'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def upgrade() -> None:
    """Upgrade schema."""
    # Add hashed_password column to users table, making it non-nullable
    op.add_column('users', sa.Column('hashed_password', sa.String(), nullable=False))
    
    # Remove the old password column
    op.drop_column('users', 'password')

    # If there's a need to handle timestamp columns (created_at, updated_at) to ensure they support timezone
    # Adding or altering 'created_at' and 'updated_at' to be TIMESTAMP WITH TIME ZONE
    # This step assumes you may have timestamp fields that need to be adjusted
    op.add_column('users', sa.Column('created_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now()))
    op.add_column('users', sa.Column('updated_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now(), onupdate=sa.func.now()))

def downgrade() -> None:
    """Downgrade schema."""
    # Add back the original password column in case of a rollback
    op.add_column('users', sa.Column('password', sa.String(), nullable=False))
    
    # Remove the hashed_password column
    op.drop_column('users', 'hashed_password')

    # Revert the 'created_at' and 'updated_at' columns to remove timezone support (optional)
    op.drop_column('users', 'created_at')
    op.drop_column('users', 'updated_at')
