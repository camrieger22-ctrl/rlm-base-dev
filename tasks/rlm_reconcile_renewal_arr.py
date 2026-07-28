"""Reconcile Amendment Studio's current ARR against the renewal opportunity.

Studio and the renewal forecast both derive from the asset but reach it by
different routes: Studio annualizes the latest AssetStatePeriod MRR
(RLM_AmendDifferenceService.installedStateByAsset), while the renewal flow
builds opportunity products from getRenewableAssetsSummary. When assetization
is correct the two agree on their own. A non-zero delta means one side was
edited by hand, the renewal opportunity never refreshed after a change, or the
asset itself is corrupt.

Note the two are not the same measure. Studio reports a run rate off the latest
state period; the opportunity values the renewal term. Mid-term ramps, renewal
uplift, and partial terms all separate them legitimately, so treat a delta as a
prompt to look rather than proof of a defect.
"""

import requests

try:
    from cumulusci.core.tasks import BaseTask
    from cumulusci.core.exceptions import CommandException
except ImportError:  # keeps the module importable for linting without CCI
    BaseTask = object
    CommandException = Exception

RENEWAL_OPPORTUNITY_NAME = "Renewal Forecast Opportunity"


class ReconcileRenewalArr(BaseTask):
    task_options = {
        "account": {
            "description": "Limit the check to one account name (default: all accounts)",
            "required": False,
        },
        "opportunity_name": {
            "description": (
                "Name of the renewal opportunity to compare against "
                f"(default: {RENEWAL_OPPORTUNITY_NAME})"
            ),
            "required": False,
        },
        "tolerance": {
            "description": "Absolute currency delta treated as agreement (default: 0.01)",
            "required": False,
        },
        "fail_on_drift": {
            "description": "Raise instead of warn when an account drifts (default: False)",
            "required": False,
        },
        "verbose": {
            "description": "Log every account, not just the ones that drift (default: False)",
            "required": False,
        },
    }

    def _run_task(self):
        account = self.options.get("account")
        opp_name = self.options.get("opportunity_name") or RENEWAL_OPPORTUNITY_NAME
        tolerance = float(self.options.get("tolerance") or 0.01)
        fail_on_drift = self._flag("fail_on_drift")
        verbose = self._flag("verbose")

        studio = self._studio_arr_by_account(account)
        renewal = self._renewal_amount_by_account(opp_name, account)

        checked, drifted = self._report(studio, renewal, tolerance, verbose)

        if not checked:
            self.logger.info("No accounts with assets or renewal opportunities.")
            return

        if not drifted:
            self.logger.info(f"All {checked} account(s) reconcile.")
            return

        message = f"{len(drifted)} of {checked} account(s) drifted"
        if fail_on_drift:
            raise CommandException(message)
        self.logger.warning(message)

    def _report(self, studio, renewal, tolerance, verbose):
        """Log the comparison and return (accounts checked, names that disagree).

        Only drifting accounts are logged unless verbose is set, so the common
        clean result stays a single line.
        """
        accounts = sorted(set(studio) | set(renewal))
        drifted = []
        for name in accounts:
            studio_arr = studio.get(name, 0.0)
            renewal_amount = renewal.get(name, 0.0)
            delta = studio_arr - renewal_amount
            if abs(delta) > tolerance:
                drifted.append(name)
                self.logger.warning(
                    f"{name}: delta {delta:,.2f} "
                    f"(studio {studio_arr:,.2f}, renewal {renewal_amount:,.2f})"
                )
            elif verbose:
                self.logger.info(f"{name}: {studio_arr:,.2f} reconciled")
        return len(accounts), drifted

    def _flag(self, name):
        return str(self.options.get(name, False)).strip().lower() in (
            "true",
            "1",
            "yes",
        )

    def _studio_arr_by_account(self, account):
        """Annualized MRR of the latest state period per asset, summed per account.

        Mirrors RLM_AmendDifferenceService.installedStateByAsset: order by asset
        then start date descending and keep the first period seen for each asset.
        """
        soql = (
            "SELECT AssetId, Asset.Account.Name, Mrr, StartDate "
            "FROM AssetStatePeriod "
            "WHERE Asset.AccountId != null"
        )
        if account:
            soql += f" AND Asset.Account.Name = '{self._escape(account)}'"
        soql += " ORDER BY AssetId, StartDate DESC"

        arr_by_account = {}
        seen_assets = set()
        for record in self._query(soql):
            asset_id = record["AssetId"]
            if asset_id in seen_assets:
                continue
            seen_assets.add(asset_id)
            name = record["Asset"]["Account"]["Name"]
            arr_by_account[name] = arr_by_account.get(name, 0.0) + (
                record["Mrr"] or 0
            ) * 12
        return arr_by_account

    def _renewal_amount_by_account(self, opp_name, account):
        soql = (
            "SELECT Account.Name, Amount FROM Opportunity "
            f"WHERE Name = '{self._escape(opp_name)}' "
            "AND IsClosed = false AND AccountId != null"
        )
        if account:
            soql += f" AND Account.Name = '{self._escape(account)}'"

        amount_by_account = {}
        for record in self._query(soql):
            name = record["Account"]["Name"]
            amount_by_account[name] = amount_by_account.get(name, 0.0) + (
                record["Amount"] or 0
            )
        return amount_by_account

    def _query(self, soql):
        """Run a SOQL query, following queryLocator pages."""
        api_version = self.project_config.project__package__api_version
        url = f"{self.org_config.instance_url}/services/data/v{api_version}/query/"
        headers = {"Authorization": f"Bearer {self.org_config.access_token}"}

        records = []
        response = requests.get(url, headers=headers, params={"q": soql})
        while True:
            if not response.ok:
                raise CommandException(f"Query failed: {response.text}")
            payload = response.json()
            records.extend(payload.get("records", []))
            next_url = payload.get("nextRecordsUrl")
            if not next_url:
                return records
            response = requests.get(
                f"{self.org_config.instance_url}{next_url}", headers=headers
            )

    @staticmethod
    def _escape(value):
        return value.replace("\\", "\\\\").replace("'", "\\'")
