module RfcHistory
  def history
    @ci = ci_resource
    @rfc_cis = Cms::RfcCi.all(:params => {:ciId => @ci.ciId})
    @rfc_relations = Cms::RfcRelation.all(:params => {:ciId => @ci.ciId})

    respond_to do |format|
      format.html {render 'base/rfc_history/history'}
      format.json {render :json => {:rfc_cis => @rfc_cis, :rfc_relations => @rfc_relations}}
    end
  end
end
