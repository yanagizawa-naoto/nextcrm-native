import { definePlugin } from "@nextcrm/plugin-sdk";
import { lookupAres } from "./ares";
import { validateVies } from "./vies";

export default definePlugin({
  id: "registry-ares",
  name: "企業登録情報（ARES・VIES）",
  version: "0.1.0",
  sdk: "^0.2.0",
  description: "チェコの企業登録情報をARESから取得し、EUの税務登録番号をVIESで確認します。",
  permissions: ["http"],
  extensions: (x) => {
    x.companyRegistry({
      countries: ["CZ"],
      lookup: (registrationNumber, _country, ctx) => lookupAres(registrationNumber, ctx),
      validateVat: (vat, ctx) => validateVies(vat, ctx),
    });
  },
});
