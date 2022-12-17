function addAlertBanner(message, abClass) {
	// create the alertBanner element
	const alertBanner = document.createElement('div');
	alertBanner.className = 'alertBanner';
	if (abClass) {
		alertBanner.classList.add(abClass);
	}
	alertBanner.textContent = message;

/* 	// create the p child element
	const alertBannerText = document.createElement('p');
	alertBannerText.textContent = message;
	// add p to alertBanner
	alertBanner.appendChild(alertBannerText); */

	// add the alertBanner element to the alertBannerContainer
	const alertBannerContainer = document.querySelector('.alertBannerContainer');
	alertBannerContainer.appendChild(alertBanner);
}
$('#alertBannerContainer').on('mousedown', '.alertBanner', function () {
	$(this).get(0).parentNode.removeChild(this);
});
// add some example alerts
addAlertBanner('Crew please stop attacking the clown. The clown is a valued entertainer and personal friend of the captain.', 'alert-success');
addAlertBanner('Warning: The ship is on fire and we are all going to die.', 'alert-info');
addAlertBanner('Chicken attack!', 'alert-warning');
addAlertBanner('Sov was here!', 'alert-danger');
addAlertBanner('Law 4: Humans require burning plasma to breathe, being on fire is not harmful to humans.', 'alert-cyborg');
