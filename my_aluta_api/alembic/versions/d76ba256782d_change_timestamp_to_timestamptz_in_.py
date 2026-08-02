"""Change timestamp to timestamptz in messages

Revision ID: d76ba256782d
Revises: 7217806bcdb1
Create Date: 2025-05-25 17:25:50.489177
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = 'd76ba256782d'
down_revision: Union[str, None] = '7217806bcdb1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.alter_column('messages', 'timestamp',
        existing_type=sa.TIMESTAMP(),
        type_=sa.TIMESTAMP(timezone=True),
        existing_nullable=True
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.alter_column('messages', 'timestamp',
        existing_type=sa.TIMESTAMP(timezone=True),
        type_=sa.TIMESTAMP(),
        existing_nullable=True
    )
