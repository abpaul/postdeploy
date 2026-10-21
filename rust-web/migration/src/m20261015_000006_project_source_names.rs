use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(
            "CREATE UNIQUE INDEX projects_org_name ON projects(org_id, name);
             CREATE UNIQUE INDEX sources_project_name_environment ON sources(project_id, name, environment);",
        ).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared(
                "DROP INDEX sources_project_name_environment; DROP INDEX projects_org_name;",
            )
            .await?;
        Ok(())
    }
}
