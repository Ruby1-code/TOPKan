const dialog = document.querySelector("#edit-dialog");
const form = document.querySelector("#edit-form");

document.querySelectorAll(".edit-button").forEach((button) => {
  button.addEventListener("click", () => {
    form.action = `/people/${button.dataset.id}/update`;
    form.elements.first_name.value = button.dataset.first;
    form.elements.last_name.value = button.dataset.last;
    form.elements.email.value = button.dataset.email;
    form.elements.password.value = "";
    form.elements.telephone1.value = button.dataset.telephone;
    form.elements.namedItem("sNumber").value = button.dataset.snumber;
    form.elements.namedItem("sName").value = button.dataset.sname;
    form.elements.comments.value = button.dataset.comments;
    form.elements.admin.checked = button.dataset.admin === "1";
    dialog.showModal();
  });
});

document.querySelectorAll(".close-dialog, #cancel-edit").forEach((button) => {
  button.addEventListener("click", () => dialog.close());
});

dialog.addEventListener("click", (event) => {
  if (event.target === dialog) dialog.close();
});
