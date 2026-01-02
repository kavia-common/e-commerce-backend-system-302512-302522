# PostgreSQL Schema Notes (applied via psql -c)

This project uses PostgreSQL with a minimal e-commerce schema designed to support:

- JWT authentication (`users.password_hash`)
- Role-based access control (RBAC) via `roles` + `user_roles`
- Product catalog (`products`)
- Order management (`orders`, `order_items`)

**Important:** The schema was applied directly via `psql -c` statements using the connection string in `database/db_connection.txt` (no migration framework in this environment).

## Extensions

- `citext` (case-insensitive email uniqueness)
- `pgcrypto` (UUID generation via `gen_random_uuid()`)

## Enums

- `user_status`: `ACTIVE`, `DISABLED`
- `order_status`: `PENDING`, `PAID`, `FULFILLED`, `CANCELLED`

## Tables

### `roles`
- `id BIGSERIAL PRIMARY KEY`
- `name TEXT UNIQUE NOT NULL`
- `description TEXT`
- `created_at`, `updated_at` (`TIMESTAMPTZ`, default `NOW()`)

### `users`
- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `email CITEXT UNIQUE NOT NULL`
- `password_hash TEXT NOT NULL`
- `full_name TEXT`
- `status user_status NOT NULL DEFAULT 'ACTIVE'`
- `created_at`, `updated_at` (`TIMESTAMPTZ`, default `NOW()`)
- `last_login_at TIMESTAMPTZ`

### `user_roles`
Many-to-many join table:
- `user_id UUID REFERENCES users(id) ON DELETE CASCADE`
- `role_id BIGINT REFERENCES roles(id) ON DELETE RESTRICT`
- `created_at TIMESTAMPTZ DEFAULT NOW()`
- `PRIMARY KEY (user_id, role_id)`

Index:
- `idx_user_roles_role_id (role_id)`

### `products`
- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `sku TEXT UNIQUE NOT NULL`
- `name TEXT NOT NULL`
- `description TEXT`
- `price_cents INTEGER NOT NULL CHECK (price_cents >= 0)`
- `currency CHAR(3) NOT NULL DEFAULT 'USD'`
- `active BOOLEAN NOT NULL DEFAULT TRUE`
- `stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0)`
- `created_at`, `updated_at`

### `orders`
- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT`
- `status order_status NOT NULL DEFAULT 'PENDING'`
- `subtotal_cents INTEGER NOT NULL CHECK (subtotal_cents >= 0)`
- `tax_cents INTEGER NOT NULL DEFAULT 0 CHECK (tax_cents >= 0)`
- `shipping_cents INTEGER NOT NULL DEFAULT 0 CHECK (shipping_cents >= 0)`
- `total_cents INTEGER NOT NULL CHECK (total_cents >= 0)`
- `currency CHAR(3) NOT NULL DEFAULT 'USD'`
- `created_at`, `updated_at`
- `paid_at`, `cancelled_at`
- Constraint: `total_cents = subtotal_cents + tax_cents + shipping_cents`

Indexes:
- `idx_orders_user_id_created_at (user_id, created_at DESC)`
- `idx_orders_status_created_at (status, created_at DESC)`

### `order_items`
- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE`
- `product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT`
- `quantity INTEGER NOT NULL CHECK (quantity > 0)`
- `unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents >= 0)`
- `line_total_cents INTEGER NOT NULL CHECK (line_total_cents >= 0)`
- `created_at`, `updated_at`
- Constraint: `line_total_cents = quantity * unit_price_cents`
- Unique: `(order_id, product_id)` (prevents duplicate product lines)

Indexes:
- `idx_order_items_order_id (order_id)`
- `idx_order_items_product_id (product_id)`

## Timestamps (`updated_at`)

A common trigger function is used:

- `set_updated_at()` sets `NEW.updated_at = NOW()` on updates
- Triggers created on:
  - `roles`
  - `users`
  - `products`
  - `orders`
  - `order_items`

## Seed data

Minimal seed inserted idempotently:

- Roles:
  - `admin`
  - `customer`
- Admin user:
  - `admin@example.com`
  - `password_hash` set to a placeholder bcrypt hash (backend should provide a password reset/change flow)
- Admin role assignment via `user_roles`

## Notes for backend integration

- Use `users.email` case-insensitively (handled by `CITEXT`).
- Store password hashes (bcrypt/argon2) in `users.password_hash`.
- Enforce authorization by joining `users -> user_roles -> roles`.
- Prefer `UUID` IDs in API responses and JWT subject claims (`sub`).
