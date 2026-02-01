CREATE TABLE IF NOT EXISTS tasks (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    image VARCHAR(255) NOT NULL,
    command TEXT[],
    priority INTEGER DEFAULT 0,
    required_cpu FLOAT DEFAULT 0,
    required_memory FLOAT DEFAULT 0,
    status VARCHAR(50) DEFAULT 'PENDING',
    assigned_node_id VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_tasks_priority ON tasks (priority DESC);
CREATE INDEX idx_tasks_status ON tasks (status);
