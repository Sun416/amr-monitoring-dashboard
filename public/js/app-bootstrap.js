'use strict';

elements.refreshButton.addEventListener('click', () => {
  loadDashboard({ announce: true });
  loadProjectAnalytics();
});
elements.exportAllButton.addEventListener('click', exportAllData);
elements.robotSearch.addEventListener('input', () => renderRobotVitals(state.dashboard?.robots || []));
function selectRobotProfile(robotId) {
  state.selectedRobotId = robotId || null;
  state.robotProfile = null;
  elements.profileRobotSelect.value = robotId || '';
  activateView('robot-profile');
}
elements.profileRobotSelect.addEventListener('change', () => selectRobotProfile(elements.profileRobotSelect.value));
elements.mapSelect.addEventListener('change', () => {
  state.selectedMapCode = elements.mapSelect.value || null;
  renderMap(state.dashboard?.robots || []);
});
// Checkbox dropdowns: option changes are wired in renderMultiSelect; these
// bindings only open/close the menus.
bindMultiSelectToggle(elements.wifiRobotToggle, elements.wifiRobotMenu);
bindMultiSelectToggle(elements.wifiPoiToggle, elements.wifiPoiMenu);
document.addEventListener('click', () => closeMultiSelectMenus(null));
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeMultiSelectMenus(null);
});
elements.wifiApplyWindow.addEventListener('click', () => {
  const start = String(elements.wifiStartTime.value || '').trim();
  const end = String(elements.wifiEndTime.value || '').trim();
  if (!start || !end) {
    showToast('Choose both exact analysis start and end times', 'error');
    return;
  }
  state.analysisWindow = { isCustom: true, start, end };
  state.selectedWifiRobot = 'ALL';
  state.selectedWifiPoi = 'ALL';
  state.selectedWifiRobots = [];
  state.selectedWifiPois = [];
  elements.analysisWindowLabel.textContent = `${robotTypeLabel()} · ${analysisWindowLabelText()}`;
  loadDashboard({ announce: true });
  loadTaskAnalytics();
  loadProjectAnalytics();
});
if (elements.windowClearButton) {
  elements.windowClearButton.addEventListener('click', () => {
    state.analysisWindow = { isCustom: false, start: null, end: null };
    if (elements.wifiStartTime) elements.wifiStartTime.value = '';
    if (elements.wifiEndTime) elements.wifiEndTime.value = '';
    elements.analysisWindowLabel.textContent = `${robotTypeLabel()} · ${analysisWindowLabelText()}`;
    loadDashboard({ announce: true });
    loadTaskAnalytics();
    loadProjectAnalytics();
  });
}
elements.taskApplyWindow.addEventListener('click', () => {
  loadTaskAnalytics({ announce: true });
});
bindMultiSelectToggle(elements.projectToggle, elements.projectMenu);
bindMultiSelectToggle(elements.taskToggle, elements.taskMenu);
bindMultiSelectToggle(elements.robotToggle, elements.robotMenu);
bindMultiSelectToggle(elements.analysisProjectToggle, elements.analysisProjectMenu);
bindMultiSelectToggle(elements.analysisTaskToggle, elements.analysisTaskMenu);
bindMultiSelectToggle(elements.analysisRobotToggle, elements.analysisRobotMenu);
if (elements.projectClearFilter) {
  elements.projectClearFilter.addEventListener('click', () => setProjectScope({ projectIds: [], jobIds: [] }));
}
if (elements.analysisClearFilter) {
  elements.analysisClearFilter.addEventListener('click', () => setProjectScope({ projectIds: [], jobIds: [] }));
}
elements.taskRobotToggle.addEventListener('click', () => {
  const opening = elements.taskRobotMenu.hidden;
  elements.taskRobotMenu.hidden = !opening;
  elements.taskRobotToggle.setAttribute('aria-expanded', String(opening));
});
document.addEventListener('click', (event) => {
  if (!elements.taskRobotMenu || elements.taskRobotMenu.hidden) return;
  if (event.target.closest('.task-robot-picker')) return;
  elements.taskRobotMenu.hidden = true;
  elements.taskRobotToggle.setAttribute('aria-expanded', 'false');
});
elements.taskTopLimitSelect.addEventListener('change', () => {
  state.taskTopLimit = Number(elements.taskTopLimitSelect.value) || 5;
  if (state.taskAnalytics) renderTaskAnalytics(state.taskAnalytics);
});
document.querySelectorAll('[data-export]').forEach((button) => {
  button.addEventListener('click', () => exportDataset(button.dataset.export));
});
document.querySelectorAll('[data-view]').forEach((button) => {
  button.addEventListener('click', () => activateView(button.dataset.view));
});
document.querySelectorAll('[data-go-view]').forEach((button) => {
  button.addEventListener('click', () => activateView(button.dataset.goView));
});
elements.sidebarToggle.addEventListener('click', () => {
  const open = !elements.sidebar.classList.contains('open');
  elements.sidebar.classList.toggle('open', open);
  elements.sidebarOverlay.classList.toggle('open', open);
  elements.sidebarToggle.setAttribute('aria-expanded', String(open));
});
elements.sidebarOverlay.addEventListener('click', closeSidebar);
window.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeSidebar(); });
window.addEventListener('hashchange', () => {
  const view = location.hash.slice(1);
  if (VIEW_META[view]) activateView(view, { updateHash: false });
});

updateClock();
window.setInterval(updateClock, 1000);
const initialView = location.hash.slice(1);
activateView(VIEW_META[initialView] ? initialView : 'projects', { updateHash: false });
loadDashboard();
loadTaskAnalytics();
loadProjectAnalytics();
