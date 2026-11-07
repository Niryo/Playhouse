export const initialState = { confirming: false, alerting: false, result: "nothing yet" };

export const actions = {
  askDelete(state) {
    state.confirming = true;
  },
  confirm(state) {
    state.confirming = false;
    state.result = "Deleted";
  },
  cancel(state) {
    state.confirming = false;
    state.result = "Cancelled";
  },
  showAlert(state) {
    state.alerting = true;
  },
  dismissAlert(state) {
    state.alerting = false;
    state.result = "Alert dismissed";
  }
};
