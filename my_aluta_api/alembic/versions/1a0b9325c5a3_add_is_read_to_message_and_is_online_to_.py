# Revision ID: 1a0b9325c5a3
# Revisions: da4ba3d29552
# Create Date: 2025-04-25 17:06:25.804211

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '1a0b9325c5a3'
down_revision: Union[str, None] = 'da4ba3d29552'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def upgrade() -> None:
    """Upgrade schema."""
    # Add 'is_read' column to the 'messages' table, making it non-nullable
    op.add_column('messages', sa.Column('is_read', sa.Boolean(), nullable=False))

    # Add 'is_online' column to the 'users' table, making it non-nullable
    op.add_column('users', sa.Column('is_online', sa.Boolean(), nullable=False))
    
    # If there are any timestamp fields in 'users' or 'messages' table, alter them to support timezones
    # Adding 'created_at' and 'updated_at' with timezone for both tables (users and messages)
    op.add_column('users', sa.Column('created_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now()))
    op.add_column('users', sa.Column('updated_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now(), onupdate=sa.func.now()))
    
    op.add_column('messages', sa.Column('created_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now()))
    op.add_column('messages', sa.Column('updated_at', sa.TIMESTAMP(timezone=True), nullable=False, server_default=sa.func.now(), onupdate=sa.func.now()))

def downgrade() -> None:
    """Downgrade schema."""
    # Remove 'is_online' column from the 'users' table
    op.drop_column('users', 'is_online')
    
    # Remove 'is_read' column from the 'messages' table
    op.drop_column('messages', 'is_read')

    # Remove 'created_at' and 'updated_at' columns from both tables if rolling back
    op.drop_column('users', 'created_at')
    op.drop_column('users', 'updated_at')
    
    op.drop_column('messages', 'created_at')
    op.drop_column('messages', 'updated_at')
