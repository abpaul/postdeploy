//! How far an organization is from receiving events and having an agent.

use sea_orm::ConnectionTrait;

use crate::{
    agent_access::{Scope, ScopeSet},
    domain::{now_secs, ProjectId, SourceId},
    error::ApiResult,
    identity::{access::OrgAccess, projects::Project},
    ingest,
    runtime::{sql, Runtime},
};

/// The ingestion path, in the order a member completes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Setup {
    NoProject,
    NoSource {
        project: ProjectId,
    },
    AwaitingFirstEvent {
        project: ProjectId,
        source: SourceId,
    },
    Receiving,
}

/// The strongest live agent credential of the organization: an OAuth grant or
/// an API key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Agent {
    None,
    Connected,
    CanCreateProjects,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Onboarding {
    pub setup: Setup,
    pub agent: Agent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Organization,
    Project,
    Source,
    FirstEvent,
    Agent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StepState {
    Done,
    Current,
    Todo,
}

impl Onboarding {
    pub fn is_done(&self) -> bool {
        self.setup == Setup::Receiving && self.agent != Agent::None
    }

    /// Every step with its state. The first step not done is current.
    pub fn steps(&self) -> [(Step, StepState); 5] {
        let reached = match self.setup {
            Setup::NoProject => 1,
            Setup::NoSource { .. } => 2,
            Setup::AwaitingFirstEvent { .. } => 3,
            Setup::Receiving => 4,
        };
        let order = [
            Step::Organization,
            Step::Project,
            Step::Source,
            Step::FirstEvent,
            Step::Agent,
        ];
        let done = |index: usize| match order[index] {
            Step::Agent => self.agent != Agent::None,
            _ => index < reached,
        };
        let current = (0..order.len()).find(|index| !done(*index));
        std::array::from_fn(|index| {
            let state = if done(index) {
                StepState::Done
            } else if Some(index) == current {
                StepState::Current
            } else {
                StepState::Todo
            };
            (order[index], state)
        })
    }
}

pub async fn load(rt: &Runtime, access: &OrgAccess, projects: &[Project]) -> ApiResult<Onboarding> {
    Ok(Onboarding {
        setup: setup(rt, access, projects).await?,
        agent: agent(rt, access).await?,
    })
}

async fn setup(rt: &Runtime, access: &OrgAccess, projects: &[Project]) -> ApiResult<Setup> {
    let Some(project) = projects.first() else {
        return Ok(Setup::NoProject);
    };
    let first_source = rt
        .control
        .query_one_raw(sql(
            "SELECT project_id, id FROM sources WHERE org_id = ? ORDER BY id LIMIT 1",
            vec![access.org.as_str().into()],
        ))
        .await?;
    let Some(row) = first_source else {
        return Ok(Setup::NoSource {
            project: project.id,
        });
    };
    let project = ProjectId(row.try_get_by_index(0)?);
    let source = SourceId(row.try_get_by_index(1)?);
    let arrival = ingest::arrival(rt, &access.org, project, source).await?;
    Ok(if arrival.errors_received || arrival.logs_received {
        Setup::Receiving
    } else {
        Setup::AwaitingFirstEvent { project, source }
    })
}

async fn agent(rt: &Runtime, access: &OrgAccess) -> ApiResult<Agent> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT scopes FROM oauth_grants WHERE org_id = ? AND revoked_at IS NULL
             UNION ALL
             SELECT scopes FROM agent_api_keys
             WHERE org_id = ? AND revoked_at IS NULL AND expires_at > ?",
            vec![
                access.org.as_str().into(),
                access.org.as_str().into(),
                now_secs().into(),
            ],
        ))
        .await?;
    let mut agent = Agent::None;
    for row in rows {
        let scopes = ScopeSet::parse(&row.try_get_by_index::<String>(0)?);
        let level = if scopes.is_some_and(|scopes| scopes.contains(Scope::ProjectsWrite)) {
            Agent::CanCreateProjects
        } else {
            Agent::Connected
        };
        agent = agent.max(level);
    }
    Ok(agent)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn states(onboarding: Onboarding) -> Vec<StepState> {
        onboarding.steps().iter().map(|(_, state)| *state).collect()
    }

    #[test]
    fn the_first_unfinished_step_is_current() {
        use StepState::{Current, Done, Todo};
        let fresh = Onboarding {
            setup: Setup::NoProject,
            agent: Agent::None,
        };
        assert_eq!(states(fresh), [Done, Current, Todo, Todo, Todo]);
        assert!(!fresh.is_done());

        let agent_first = Onboarding {
            setup: Setup::NoProject,
            agent: Agent::CanCreateProjects,
        };
        assert_eq!(states(agent_first), [Done, Current, Todo, Todo, Done]);

        let waiting = Onboarding {
            setup: Setup::AwaitingFirstEvent {
                project: ProjectId(1),
                source: SourceId(2),
            },
            agent: Agent::None,
        };
        assert_eq!(states(waiting), [Done, Done, Done, Current, Todo]);

        let receiving = Onboarding {
            setup: Setup::Receiving,
            agent: Agent::None,
        };
        assert_eq!(states(receiving), [Done, Done, Done, Done, Current]);
        assert!(!receiving.is_done());

        let done = Onboarding {
            setup: Setup::Receiving,
            agent: Agent::Connected,
        };
        assert_eq!(states(done), [Done; 5]);
        assert!(done.is_done());
    }
}
